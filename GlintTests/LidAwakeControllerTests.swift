import Darwin
import XCTest
@testable import Glint

final class LidAwakePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let limits = LidAwakePolicy.Limits(waitLimit: 1_800, stallLimit: 7_200)

    private func hold(_ status: PaneAgentStatus,
                      eventAgo: TimeInterval,
                      progressAgo: TimeInterval? = nil,
                      alive: Bool = true) -> LidAwakePolicy.PaneHold {
        LidAwakePolicy.classify(status: status,
                                updatedAt: now.addingTimeInterval(-eventAgo),
                                lastProgress: now.addingTimeInterval(-(progressAgo ?? eventAgo)),
                                agentAlive: alive,
                                now: now,
                                limits: limits)
    }

    func testRecentWorkKeepsAwakeForEveryWorkingStatus() {
        for status in [PaneAgentStatus.thinking, .tool, .compacting] {
            XCTAssertEqual(hold(status, eventAgo: 60), .working)
        }
    }

    func testChildCPUKeepsALongSilentToolRunning() {
        // Six hours without a hook event, still compiling a minute ago.
        XCTAssertEqual(hold(.tool, eventAgo: 21_600, progressAgo: 60), .working)
    }

    func testNoProgressStallsAtTheLimit() {
        XCTAssertEqual(hold(.thinking, eventAgo: 7_199), .working)
        XCTAssertEqual(hold(.thinking, eventAgo: 7_200), .stalled)
        XCTAssertFalse(LidAwakePolicy.PaneHold.stalled.keepsAwake)
    }

    func testWaitingForTheUserExpiresAtTheWaitLimit() {
        for status in [PaneAgentStatus.needsPermission, .needsReply] {
            XCTAssertEqual(hold(status, eventAgo: 1_799), .waiting)
            XCTAssertEqual(hold(status, eventAgo: 1_800), .waitExpired)
        }
        XCTAssertFalse(LidAwakePolicy.PaneHold.waitExpired.keepsAwake)
    }

    func testCPUCannotExtendAWaitingPane() {
        // Waiting is decided by the status alone; an MCP server's chatter under
        // a blocked agent must not keep the Mac up.
        XCTAssertEqual(hold(.needsReply, eventAgo: 1_800, progressAgo: 1), .waitExpired)
    }

    func testFinishedTurnGetsAGracePeriod() {
        for status in [PaneAgentStatus.idle, .justCompleted, .failed] {
            XCTAssertEqual(hold(status, eventAgo: 299), .finishing)
            XCTAssertEqual(hold(status, eventAgo: 300), .none)
        }
    }

    func testDeadAgentHoldsNothingWhateverItsStatusSays() {
        XCTAssertEqual(hold(.thinking, eventAgo: 1, alive: false), .none)
        XCTAssertEqual(hold(.needsPermission, eventAgo: 1, alive: false), .none)
    }

    func testBatteryBlocksOnlyOnBatteryAtOrBelowTheFloor() {
        func block(_ onBattery: Bool, _ percent: Int) -> LidAwakePolicy.Block? {
            LidAwakePolicy.block(battery: LidAwakeBattery(onBattery: onBattery, percent: percent),
                                 floorPercent: 20, thermal: .nominal)
        }
        XCTAssertNil(block(true, 21))
        XCTAssertEqual(block(true, 20), .battery)
        XCTAssertNil(block(false, 5))
    }

    func testOnlyCriticalHeatBlocks() {
        XCTAssertNil(LidAwakePolicy.block(battery: nil, floorPercent: 20, thermal: .serious))
        XCTAssertEqual(LidAwakePolicy.block(battery: nil, floorPercent: 20, thermal: .critical), .thermal)
    }

    func testProgressThresholdIsAShareOfOneCore() {
        XCTAssertTrue(LidAwakePolicy.madeProgress(cpuDelta: 250_000_000, elapsed: 5))
        XCTAssertFalse(LidAwakePolicy.madeProgress(cpuDelta: 249_000_000, elapsed: 5))
        XCTAssertFalse(LidAwakePolicy.madeProgress(cpuDelta: 1_000_000_000, elapsed: 0))
    }

    func testSleepNowOnlyForAnUnattendedClosedLaptop() {
        func sleeps(lid: Bool? = true, disabled: Bool? = false,
                    external: Bool = false, idle: TimeInterval = 600) -> Bool {
            LidAwakePolicy.shouldSleepNow(lidClosed: lid, sleepDisabled: disabled,
                                          hasExternalDisplay: external, userIdle: idle)
        }
        XCTAssertTrue(sleeps())
        XCTAssertFalse(sleeps(lid: false))
        XCTAssertFalse(sleeps(lid: nil))
        XCTAssertFalse(sleeps(disabled: true), "another app still wants the Mac awake")
        XCTAssertFalse(sleeps(disabled: nil))
        XCTAssertFalse(sleeps(external: true), "docked with the lid closed")
        XCTAssertFalse(sleeps(idle: 30), "someone is on it over remote desktop")
    }
}

final class LidAwakeSystemTests: XCTestCase {
    private let one = "/usr/bin/pmset -a disablesleep 1"
    private let zero = "/usr/bin/pmset -a disablesleep 0"

    /// Real output from a Mac with Amphetamine's PowerProtect rule.
    private let amphetamine = """
    User longshun may run the following commands on MacBook-Air:
        (ALL) ALL
        (ALL) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
        (ALL) NOPASSWD: /Library/Mole/mole-admin *
    """

    func testAcceptsAnExistingNoPasswordRule() {
        XCTAssertTrue(LidAwakeSystem.noPasswordAllows(amphetamine, command: one))
        XCTAssertTrue(LidAwakeSystem.noPasswordAllows(amphetamine, command: zero))
    }

    func testRejectsARuleThatStillAsksForAPassword() {
        let sudoList = """
        User me may run the following commands on host:
            (ALL) ALL
            (ALL) NOPASSWD: /Library/Mole/mole-admin *
        """
        XCTAssertFalse(LidAwakeSystem.noPasswordAllows(sudoList, command: one))
    }

    func testIgnoresTheDefaultsSectionAboveTheRules() {
        let sudoList = """
        Matching Defaults entries for me on host:
            (ALL) NOPASSWD: /usr/bin/pmset -a disablesleep 1
        User me may run the following commands on host:
            (ALL) ALL
        """
        XCTAssertFalse(LidAwakeSystem.noPasswordAllows(sudoList, command: one))
    }

    func testRejectsARuleForAnotherRunAsUser() {
        let sudoList = """
        User me may run the following commands on host:
            (nobody) NOPASSWD: /usr/bin/pmset -a disablesleep 1
        """
        XCTAssertFalse(LidAwakeSystem.noPasswordAllows(sudoList, command: one))
    }

    func testTagsCarryOverAndCanBeSwitchedOff() {
        let sudoList = """
        User me may run the following commands on host:
            (root) NOPASSWD: /bin/ls, /usr/bin/pmset -a disablesleep 1, PASSWD: /usr/bin/pmset -a disablesleep 0
        """
        XCTAssertTrue(LidAwakeSystem.noPasswordAllows(sudoList, command: one))
        XCTAssertFalse(LidAwakeSystem.noPasswordAllows(sudoList, command: zero))
    }

    func testAcceptsAWholeProgramRule() {
        let sudoList = """
        User me may run the following commands on host:
            (root) NOPASSWD: /usr/bin/pmset
        """
        XCTAssertTrue(LidAwakeSystem.noPasswordAllows(sudoList, command: one))
    }

    func testParsesSleepDisabled() {
        XCTAssertEqual(LidAwakeSystem.parseSleepDisabled("System-wide power settings:\n SleepDisabled\t\t1\n"), true)
        XCTAssertEqual(LidAwakeSystem.parseSleepDisabled(" SleepDisabled\t\t0\n sleep 0\n"), false)
        XCTAssertNil(LidAwakeSystem.parseSleepDisabled(" sleep 0\n"))
    }

    func testFindsKnownSleepManagers() {
        let ps = "/Applications/UURemote.app/Contents/MacOS/UURemoteService\n/sbin/launchd\n/Applications/Amphetamine.app/Contents/MacOS/Amphetamine\n"
        XCTAssertEqual(LidAwakeSystem.runningSleepManagers(ps), ["Amphetamine", "UU Remote"])
    }

    func testInstallScriptGrantsOnlyTheTwoCommandsAndValidatesFirst() throws {
        let script = try XCTUnwrap(LidAwakeSystem.installScript(user: "longshun"))
        XCTAssertTrue(script.contains("longshun ALL=(root) NOPASSWD: \(one), \(zero)"))
        let validate = try XCTUnwrap(script.range(of: "visudo -cf"))
        let install = try XCTUnwrap(script.range(of: "/bin/mv -f"))
        XCTAssertLessThan(validate.lowerBound, install.lowerBound)
    }

    func testInstallScriptRefusesAUserNameThatCouldBreakOut() {
        XCTAssertNil(LidAwakeSystem.installScript(user: "a'; rm -rf /; '"))
        XCTAssertNil(LidAwakeSystem.installScript(user: ""))
        XCTAssertNil(LidAwakeSystem.installScript(user: "名字"))
    }

    func testAppleScriptEscapesQuotes() {
        let script = LidAwakeSystem.appleScript(#"printf "%s""#, prompt: #"say "hi""#)
        XCTAssertEqual(script, #"do shell script "printf \"%s\"" with prompt "say \"hi\"" with administrator privileges"#)
    }

    func testCPUTimeReportsRealNanoseconds() throws {
        // proc_taskinfo counts in Mach ticks on Apple Silicon; an unconverted
        // value is about 24× too small here, which would hide every real build.
        let pid = getpid()
        let before = try XCTUnwrap(GhosttySurfaceView.cpuNanoseconds(of: pid))
        let started = Date()
        var sink: UInt64 = 0
        while Date().timeIntervalSince(started) < 0.2 { sink &+= 1 }
        XCTAssertGreaterThan(sink, 0)
        let after = try XCTUnwrap(GhosttySurfaceView.cpuNanoseconds(of: pid))
        XCTAssertGreaterThan(after - before, 150_000_000)
        XCTAssertLessThan(after - before, 2_000_000_000)
    }
}

final class LidSleepEngineTests: XCTestCase {
    private final class FakeWatcher: LidSleepWatcher {
        var isRunning = true
        var stopped = false
        func stop() { stopped = true; isRunning = false }
    }

    /// A pretend Mac: `system` is the real SleepDisabled, `commands` what ran.
    private final class Mac {
        var system = false
        var authorized = true
        var switchWorks = true
        var marker = false
        var watcherStarts = true
        var watchers: [FakeWatcher] = []
        var commands: [String] = []
        var pmsetReadable = true

        func run(_ path: String, _ arguments: [String], _ timeout: TimeInterval) -> LidSleepEngine.CommandResult {
            let line = ([path] + arguments).joined(separator: " ")
            commands.append(line)
            if line.hasSuffix("pmset -g") {
                return pmsetReadable
                    ? .init(code: 0, out: " SleepDisabled\t\t\(system ? 1 : 0)\n", err: "")
                    : .init(code: 1, out: "", err: "nope")
            }
            if arguments == ["-n", "-l"] {
                guard authorized else { return .init(code: 1, out: "", err: "password required") }
                return .init(code: 0, out: """
                User me may run the following commands on host:
                    (ALL) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
                """, err: "")
            }
            if line.contains("-a disablesleep") {
                guard switchWorks else { return .init(code: 1, out: "", err: "denied") }
                system = arguments.last == "1"
                return .init(code: 0, out: "", err: "")
            }
            if path == "/bin/ps" {
                return .init(code: 0, out: "/Applications/UURemote.app/Contents/MacOS/UURemoteService\n", err: "")
            }
            return .init(code: 0, out: "", err: "")
        }

        var switchCommands: [String] { commands.filter { $0.contains("-a disablesleep") } }

        func engine() -> LidSleepEngine {
            LidSleepEngine(run: run,
                           loadMarker: { self.marker },
                           saveMarker: { self.marker = $0 },
                           spawnWatcher: { _ in
                               guard self.watcherStarts else { return nil }
                               let watcher = FakeWatcher()
                               self.watchers.append(watcher)
                               return watcher
                           },
                           currentPID: 1)
        }
    }

    func testEngagingSetsTheSwitchWithAWatcherAndMarker() {
        let mac = Mac()
        let status = mac.engine().reconcile(want: true)
        XCTAssertTrue(status.engaged)
        XCTAssertTrue(status.keepingAwake)
        XCTAssertTrue(mac.system)
        XCTAssertTrue(mac.marker)
        XCTAssertEqual(mac.watchers.count, 1)
    }

    func testReleasingClearsEverythingItSet() {
        let mac = Mac()
        let engine = mac.engine()
        engine.reconcile(want: true)
        let status = engine.reconcile(want: false)
        XCTAssertFalse(status.engaged)
        XCTAssertFalse(mac.system)
        XCTAssertFalse(mac.marker)
        XCTAssertTrue(mac.watchers[0].stopped)
    }

    func testAValueSetByAnotherAppIsNeverTouched() {
        let mac = Mac()
        mac.system = true
        let engine = mac.engine()
        let holding = engine.reconcile(want: true)
        XCTAssertFalse(holding.engaged)
        XCTAssertTrue(holding.heldByOther)
        XCTAssertTrue(holding.keepingAwake)
        XCTAssertFalse(mac.marker)

        let released = engine.reconcile(want: false)
        XCTAssertFalse(released.keepingAwake)
        XCTAssertTrue(mac.system, "not ours to clear")
        XCTAssertEqual(mac.switchCommands, [])
    }

    func testTakesOverWhenTheOtherAppLetsGo() {
        let mac = Mac()
        mac.system = true
        let engine = mac.engine()
        engine.reconcile(want: true)
        mac.system = false
        let status = engine.reconcile(want: true)
        XCTAssertTrue(status.engaged)
        XCTAssertFalse(status.heldByOther)
        XCTAssertTrue(mac.system)
    }

    func testRestoresTheSwitchWhenSomethingClearsIt() {
        let mac = Mac()
        let engine = mac.engine()
        engine.reconcile(want: true)
        mac.system = false
        let status = engine.reconcile(want: true)
        XCTAssertTrue(mac.system)
        XCTAssertEqual(status.overrides, 1)
        XCTAssertEqual(status.lastCulprits, ["UU Remote"])
        XCTAssertNil(status.failure)
    }

    func testRestartsADeadWatcher() {
        let mac = Mac()
        let engine = mac.engine()
        engine.reconcile(want: true)
        mac.watchers[0].isRunning = false
        engine.reconcile(want: true)
        XCTAssertEqual(mac.watchers.count, 2)
    }

    func testNoWatcherMeansNoSwitch() {
        let mac = Mac()
        mac.watcherStarts = false
        let status = mac.engine().reconcile(want: true)
        XCTAssertFalse(status.keepingAwake)
        XCTAssertEqual(status.failure, .watcherFailed)
        XCTAssertFalse(mac.system)
        XCTAssertFalse(mac.marker)
    }

    func testUnauthorizedNeverTouchesTheSwitch() {
        let mac = Mac()
        mac.authorized = false
        let status = mac.engine().reconcile(want: true)
        XCTAssertEqual(status.failure, .notAuthorized)
        XCTAssertEqual(mac.switchCommands, [])
    }

    func testUnreadableStateChangesNothing() {
        let mac = Mac()
        mac.pmsetReadable = false
        let status = mac.engine().reconcile(want: true)
        XCTAssertFalse(status.engaged)
        XCTAssertEqual(mac.switchCommands, [])
    }

    func testRecoversASwitchLeftByACrash() {
        let mac = Mac()
        mac.system = true
        mac.marker = true
        mac.engine().recoverAfterCrash()
        XCTAssertFalse(mac.system)
        XCTAssertFalse(mac.marker)
    }

    func testRecoveryLeavesAnotherAppsSwitchAlone() {
        let mac = Mac()
        mac.system = true
        mac.engine().recoverAfterCrash()
        XCTAssertTrue(mac.system)
        XCTAssertEqual(mac.switchCommands, [])
    }

    func testReleaseWithAFailingSwitchKeepsTheMarkerForNextLaunch() {
        let mac = Mac()
        let engine = mac.engine()
        engine.reconcile(want: true)
        mac.switchWorks = false
        let status = engine.reconcile(want: false)
        XCTAssertEqual(status.failure, .switchFailed)
        XCTAssertTrue(mac.marker)
    }
}
