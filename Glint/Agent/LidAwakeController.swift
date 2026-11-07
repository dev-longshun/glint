import AppKit
import Combine
import CoreGraphics
import Foundation
import IOKit
import IOKit.ps

/// Fork: keep a MacBook awake with the lid closed while agents do real work,
/// and let it sleep as soon as they don't.
///
/// caffeinate / IOPMAssertion only stop *idle* sleep. Closing the lid is stopped
/// by nothing short of `pmset -a disablesleep 1`, which needs root and survives
/// reboots. So the three layers here are:
///  - `LidAwakePolicy`: pure decisions — is this pane worth staying awake for?
///  - `LidSleepEngine`: owns the system switch via `sudo -n`, on a serial queue.
///  - `LidAwakeController`: samples the panes and connects the two to the UI.
///
/// No Team ID in this fork means no privileged helper; a sudoers rule limited to
/// the two exact pmset commands is the only route. An existing rule for them
/// (Amphetamine's PowerProtect) is used as-is, without a password prompt.
enum LidAwakePolicy {
    struct Limits: Equatable {
        /// How long a pane that is certainly blocked on the user keeps the Mac up.
        var waitLimit: TimeInterval
        /// How long a "working" pane may show no progress at all.
        var stallLimit: TimeInterval
        /// Time to read the result or answer from Telegram after a turn ends.
        var finishGrace: TimeInterval = 300
    }

    enum PaneHold: Equatable {
        case working, waiting, finishing
        /// Reported as running, but nothing has moved for `stallLimit`.
        case stalled
        /// Blocked on the user past `waitLimit`.
        case waitExpired
        case none

        var keepsAwake: Bool {
            switch self {
            case .working, .waiting, .finishing: return true
            case .stalled, .waitExpired, .none: return false
            }
        }
    }

    enum Block: Equatable { case battery, thermal }

    /// Child CPU counts as progress from this share of one core. The agent's
    /// own process is excluded and so is terminal output: a spinner keeps both
    /// busy on a turn that is completely stuck.
    static let progressCPUShare = 0.05
    /// A release can be a one-tick blip, and a Telegram notice needs time to
    /// leave; never sleep the Mac faster than this.
    static let sleepDelay: TimeInterval = 30
    /// Input this recent means someone is at the Mac, likely over remote desktop.
    static let userPresentWithin: TimeInterval = 120

    /// Exhaustive on purpose: a new status has to pick a side here.
    ///
    /// A background job (Monitor, `run_in_background`) outlives the turn that
    /// started it, so a finished agent still holds while one runs. It can't
    /// beat the stall limit by merely existing: a forgotten dev server looks
    /// the same, so only hook events and its CPU restart that clock.
    static func classify(status: PaneAgentStatus,
                         updatedAt: Date,
                         lastProgress: Date,
                         agentAlive: Bool,
                         backgroundJob: Bool,
                         lastBackgroundJob: Date?,
                         now: Date,
                         limits: Limits) -> PaneHold {
        let quiet = now.timeIntervalSince(max(updatedAt, lastProgress))
        switch status {
        case .thinking, .tool, .compacting:
            guard agentAlive else { return .none }
            return quiet < limits.stallLimit ? .working : .stalled
        case .needsPermission, .needsReply:
            guard agentAlive else { return .none }
            let waited = backgroundJob ? quiet : now.timeIntervalSince(updatedAt)
            return waited < limits.waitLimit ? .waiting : .waitExpired
        case .idle, .justCompleted, .failed:
            if agentAlive && backgroundJob {
                return quiet < limits.stallLimit ? .working : .stalled
            }
            // Measured from the job's end too: the agent usually wakes on it,
            // and dropping the switch for that one tick could sleep the Mac.
            let finished = max(updatedAt, lastBackgroundJob ?? updatedAt)
            return now.timeIntervalSince(finished) < limits.finishGrace ? .finishing : .none
        }
    }

    static func block(battery: LidAwakeBattery?,
                      floorPercent: Int,
                      thermal: ProcessInfo.ThermalState) -> Block? {
        if thermal == .critical { return .thermal }
        if let battery, battery.onBattery, battery.percent <= floorPercent { return .battery }
        return nil
    }

    static func madeProgress(cpuDelta: UInt64, elapsed: TimeInterval) -> Bool {
        guard elapsed > 0 else { return false }
        return Double(cpuDelta) / 1_000_000_000 / elapsed >= progressCPUShare
    }

    /// The Mac's own sleep settings can leave it awake after the switch drops
    /// (`sleep 0` never idles), so a release with the lid shut has to ask for
    /// sleep. Everything here guards a Mac someone is still using.
    static func shouldSleepNow(lidClosed: Bool?,
                               sleepDisabled: Bool?,
                               hasExternalDisplay: Bool,
                               userIdle: TimeInterval) -> Bool {
        lidClosed == true
            && sleepDisabled == false
            && !hasExternalDisplay
            && userIdle >= userPresentWithin
    }
}

struct LidAwakeBattery: Equatable {
    var onBattery: Bool
    var percent: Int
}

/// Read-only system probes and the text formats they come back in.
enum LidAwakeSystem {
    static let pmset = "/usr/bin/pmset"
    static let sudo = "/usr/bin/sudo"
    static let sudoersPath = "/etc/sudoers.d/glint-lid"

    /// Programs seen rewriting SleepDisabled on their own, by process-name prefix.
    static let knownSleepManagers = ["UURemote": "UU Remote",
                                     "Amphetamine": "Amphetamine",
                                     "AlDente": "AlDente"]

    static func parseSleepDisabled(_ pmsetG: String) -> Bool? {
        for line in pmsetG.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.count >= 2, parts[0] == "SleepDisabled" { return parts[1] == "1" }
        }
        return nil
    }

    /// Does `sudo -n -l` show a root rule running `command` without a password?
    /// `sudo -n -l <command>` can't answer this: it only says the user may run
    /// it, and `(ALL) ALL` passes that while still asking for a password.
    static func noPasswordAllows(_ sudoList: String, command: String) -> Bool {
        let program = command.split(separator: " ").first.map(String.init) ?? command
        let accepted: Set<String> = [command, program, "\(program) *", "ALL"]
        var inRules = false
        for line in sudoList.split(separator: "\n").map(String.init) {
            if line.contains("may run the following commands") {
                inRules = true
                continue
            }
            guard inRules,
                  let open = line.firstIndex(of: "("),
                  line[..<open].allSatisfy(\.isWhitespace),
                  let close = line.firstIndex(of: ")") else { continue }
            let runAs = line[line.index(after: open)..<close]
                .split(separator: ":", omittingEmptySubsequences: false).first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard runAs == "ALL" || runAs == "root" else { continue }
            // sudoers tags carry over to the following commands on the line.
            var noPassword = false
            for entry in line[line.index(after: close)...].split(separator: ",") {
                var token = entry.trimmingCharacters(in: .whitespaces)
                while let colon = token.firstIndex(of: ":"),
                      token[..<colon].allSatisfy({ $0.isUppercase || $0 == "_" }) {
                    let tag = token[..<colon]
                    if tag == "NOPASSWD" { noPassword = true }
                    if tag == "PASSWD" { noPassword = false }
                    token = token[token.index(after: colon)...]
                        .trimmingCharacters(in: .whitespaces)
                }
                if noPassword && accepted.contains(token) { return true }
            }
        }
        return false
    }

    static func runningSleepManagers(_ psOutput: String) -> [String] {
        let names = psOutput.split(separator: "\n")
            .map { ($0.trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent }
        return knownSleepManagers.keys.sorted()
            .filter { prefix in names.contains { $0.hasPrefix(prefix) } }
            .compactMap { knownSleepManagers[$0] }
    }

    static func sudoersRule(user: String) -> String {
        "\(user) ALL=(root) NOPASSWD: \(pmset) -a disablesleep 1, \(pmset) -a disablesleep 0"
    }

    /// Runs as root: validate with visudo before anything lands in sudoers.d.
    /// Only a checked user name and fixed paths go in, so the single quotes hold.
    static func installScript(user: String) -> String? {
        guard !user.isEmpty, user.count <= 64,
              user.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) })
        else { return nil }
        return "set -e; tmp=$(/usr/bin/mktemp /tmp/glint-lid.XXXXXX); "
            + "printf '%s\\n' '# Glint: lets agents run with the lid closed. Revoke in Settings.' "
            + "'\(sudoersRule(user: user))' > \"$tmp\"; "
            + "/usr/sbin/visudo -cf \"$tmp\" >/dev/null; "
            + "/usr/sbin/chown root:wheel \"$tmp\"; /bin/chmod 0440 \"$tmp\"; "
            + "/bin/mkdir -p /etc/sudoers.d; /bin/mv -f \"$tmp\" \(sudoersPath)"
    }

    static var revokeScript: String {
        "\(pmset) -a disablesleep 0; /bin/rm -f \(sudoersPath)"
    }

    static func appleScript(_ shell: String, prompt: String?) -> String {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let promptClause = prompt.map { " with prompt \(quoted($0))" } ?? ""
        return "do shell script \(quoted(shell))\(promptClause) with administrator privileges"
    }

    static var sudoersInstalled: Bool {
        FileManager.default.fileExists(atPath: sudoersPath)
    }

    static func battery() -> LidAwakeBattery? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = info[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0 else { continue }
            return LidAwakeBattery(
                onBattery: info[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                percent: current * 100 / maximum)
        }
        return nil
    }

    static func lidClosed() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString,
                                               kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }

    /// Unknown counts as yes: a false "no" would sleep someone's docked desktop.
    static func hasExternalDisplay() -> Bool {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &displays, &count) == .success else { return true }
        return displays.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    static func secondsSinceUserInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                eventType: CGEventType(rawValue: ~0) ?? .mouseMoved)
    }

    static func run(_ path: String, _ arguments: [String],
                    timeout: TimeInterval) -> LidSleepEngine.CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            return .init(code: 127, out: "", err: error.localizedDescription)
        }
        let killer = DispatchWorkItem { [weak process] in process?.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        // Drain both pipes before waiting: `ps` can outgrow the pipe buffer.
        var errData = Data()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()
        killer.cancel()
        return .init(code: process.terminationStatus,
                     out: String(decoding: outData, as: UTF8.self),
                     err: String(decoding: errData, as: UTF8.self))
    }
}

protocol LidSleepWatcher: AnyObject {
    var isRunning: Bool { get }
    func stop()
}

/// Owns SleepDisabled. Not thread-safe: the controller confines it to one queue.
///
/// The switch outlives Glint and a Mac that never sleeps in a bag is the worst
/// failure here, so taking it always comes with a detached watcher that drops
/// it if Glint dies, and a marker that drops it on the next launch. A value
/// someone else set (no marker) is never touched.
final class LidSleepEngine: @unchecked Sendable {
    struct CommandResult: Equatable {
        var code: Int32
        var out: String
        var err: String
    }

    enum Failure: Equatable { case notAuthorized, switchFailed, watcherFailed }

    struct Status: Equatable {
        /// We set SleepDisabled and are responsible for clearing it.
        var engaged = false
        /// Another program already holds it at 1, which serves us just as well.
        var heldByOther = false
        var sleepDisabled: Bool?
        var overrides = 0
        var lastCulprits: [String] = []
        var failure: Failure?

        var keepingAwake: Bool { engaged || heldByOther }
    }

    typealias Run = (_ path: String, _ arguments: [String], _ timeout: TimeInterval) -> CommandResult

    private static let commandTimeout: TimeInterval = 8
    private static let authorizeTimeout: TimeInterval = 180
    private static let authorizationCacheLife: TimeInterval = 30

    private let run: Run
    private let loadMarker: () -> Bool
    private let saveMarker: (Bool) -> Void
    private let spawnWatcher: (Int32) -> LidSleepWatcher?
    private let currentPID: Int32
    private var watcher: LidSleepWatcher?
    private var status = Status()
    private var authorizationCache: (at: Date, value: Bool)?

    init(run: @escaping Run = LidAwakeSystem.run,
         loadMarker: @escaping () -> Bool,
         saveMarker: @escaping (Bool) -> Void,
         spawnWatcher: @escaping (Int32) -> LidSleepWatcher? = LidSleepEngine.spawnProcessWatcher,
         currentPID: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.run = run
        self.loadMarker = loadMarker
        self.saveMarker = saveMarker
        self.spawnWatcher = spawnWatcher
        self.currentPID = currentPID
    }

    func authorized(refresh: Bool = false) -> Bool {
        if !refresh, let cache = authorizationCache,
           Date().timeIntervalSince(cache.at) < Self.authorizationCacheLife {
            return cache.value
        }
        let result = run(LidAwakeSystem.sudo, ["-n", "-l"], Self.commandTimeout)
        // Clearing matters as much as setting: both, or it doesn't count.
        let value = result.code == 0 && [1, 0].allSatisfy {
            LidAwakeSystem.noPasswordAllows(result.out,
                                            command: "\(LidAwakeSystem.pmset) -a disablesleep \($0)")
        }
        authorizationCache = (Date(), value)
        return value
    }

    /// True on success; false when the user cancelled the password dialog.
    @discardableResult
    func authorize(prompt: String) -> Bool {
        guard let script = LidAwakeSystem.installScript(user: NSUserName()) else { return false }
        let result = run("/usr/bin/osascript",
                         ["-e", LidAwakeSystem.appleScript(script, prompt: prompt)],
                         Self.authorizeTimeout)
        authorizationCache = nil
        return result.code == 0 && authorized(refresh: true)
    }

    func revoke() {
        stopWatcher()
        let result = run("/usr/bin/osascript",
                         ["-e", LidAwakeSystem.appleScript(LidAwakeSystem.revokeScript, prompt: nil)],
                         Self.authorizeTimeout)
        authorizationCache = nil
        if result.code == 0 {
            status.engaged = false
            saveMarker(false)
        }
    }

    /// A previous run set the switch and never cleared it.
    func recoverAfterCrash() {
        guard loadMarker() else { return }
        NSLog("[glint] lid-awake: clearing SleepDisabled left by a previous run")
        if setSwitch(false) { saveMarker(false) }
    }

    /// Idempotent, and doubles as the guard: run on every tick while holding,
    /// it puts the switch back whenever something else clears it.
    @discardableResult
    func reconcile(want: Bool) -> Status {
        let system = sleepDisabledNow()
        status.sleepDisabled = system
        if want {
            if status.engaged { keepEngaged(system: system) } else { engage(system: system) }
        } else {
            release()
        }
        return status
    }

    /// A live read, not `status`: nothing polls the switch once we let go, and
    /// another app may have taken it since.
    func sleepDisabledRightNow() -> Bool? { sleepDisabledNow() }

    /// Only ever asked for after the lid-closed checks in `LidAwakePolicy`.
    func sleepNow() {
        NSLog("[glint] lid-awake: released with the lid closed, requesting sleep")
        _ = run(LidAwakeSystem.pmset, ["sleepnow"], Self.commandTimeout)
    }

    private func sleepDisabledNow() -> Bool? {
        let result = run(LidAwakeSystem.pmset, ["-g"], Self.commandTimeout)
        return result.code == 0 ? LidAwakeSystem.parseSleepDisabled(result.out) : nil
    }

    private func keepEngaged(system: Bool?) {
        if system == false {
            let culprits = run("/bin/ps", ["-axo", "comm="], Self.commandTimeout)
            status.lastCulprits = LidAwakeSystem.runningSleepManagers(culprits.out)
            status.overrides += 1
            NSLog("[glint] lid-awake: SleepDisabled was cleared by another program (%@), restoring",
                  status.lastCulprits.joined(separator: ", "))
            if setSwitch(true) {
                status.sleepDisabled = true
                status.failure = nil
            } else {
                status.failure = .switchFailed
            }
        }
        if watcher?.isRunning != true { startWatcher() }
    }

    private func engage(system: Bool?) {
        // Unreadable: changing a system switch on a guess helps nobody.
        guard let system else { return }
        if system {
            status.heldByOther = true
            status.failure = nil
            return
        }
        status.heldByOther = false
        guard authorized() else {
            status.failure = .notAuthorized
            return
        }
        guard setSwitch(true) else {
            status.failure = .switchFailed
            return
        }
        saveMarker(true)
        guard startWatcher() else { return }
        status.engaged = true
        status.sleepDisabled = true
        status.failure = nil
        NSLog("[glint] lid-awake: engaged")
    }

    /// No watcher means nobody clears the switch if Glint dies, so give it back.
    @discardableResult
    private func startWatcher() -> Bool {
        if let started = spawnWatcher(currentPID) {
            watcher = started
            return true
        }
        watcher = nil
        if setSwitch(false) { saveMarker(false) }
        status.engaged = false
        status.sleepDisabled = false
        status.failure = .watcherFailed
        return false
    }

    private func release() {
        status.heldByOther = false
        status.failure = nil
        stopWatcher()
        guard status.engaged || loadMarker() else { return }
        status.engaged = false
        if setSwitch(false) {
            saveMarker(false)
            status.sleepDisabled = false
            NSLog("[glint] lid-awake: released")
        } else {
            status.failure = .switchFailed
        }
    }

    private func stopWatcher() {
        watcher?.stop()
        watcher = nil
    }

    private func setSwitch(_ on: Bool) -> Bool {
        let result = run(LidAwakeSystem.sudo,
                         ["-n", LidAwakeSystem.pmset, "-a", "disablesleep", on ? "1" : "0"],
                         Self.commandTimeout)
        if result.code != 0 {
            NSLog("[glint] lid-awake: pmset disablesleep %d failed: %@", on ? 1 : 0, result.err)
        }
        return result.code == 0
    }

    private final class ProcessWatcher: LidSleepWatcher {
        let process: Process
        init(process: Process) { self.process = process }
        var isRunning: Bool { process.isRunning }
        func stop() { if process.isRunning { process.terminate() } }
    }

    /// A child outlives a crashed or force-quit parent, which is the whole point.
    static func spawnProcessWatcher(pid: Int32) -> LidSleepWatcher? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 3; done; "
            + "\(LidAwakeSystem.sudo) -n \(LidAwakeSystem.pmset) -a disablesleep 0"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return ProcessWatcher(process: process)
        } catch {
            NSLog("[glint] lid-awake: watcher failed to start: %@", error.localizedDescription)
            return nil
        }
    }
}

struct LidAwakePaneSample {
    var handle: String
    var status: PaneAgentStatus
    var updatedAt: Date
    var agentAlive: Bool
    /// Nil unless the pane is working or has a background job: CPU only
    /// matters for telling a long run from a stall.
    var childCPUNanoseconds: UInt64?
    var backgroundJobRunning: Bool
}

@MainActor
protocol LidAwakeHost: AnyObject {
    func lidAwakePanes() -> [LidAwakePaneSample]
    func confirmationTitle(forPane pane: String) -> String?
}

@MainActor
final class LidAwakeController: ObservableObject {
    static let shared = LidAwakeController()

    enum Phase: Equatable {
        case off
        case standby
        case working(Int)
        case waiting(Int)
        case blocked(LidAwakePolicy.Block)
    }

    static let waitLimitChoices = [900, 1_800, 3_600, 7_200]
    static let stallLimitChoices = [1_800, 3_600, 7_200, 14_400]
    static let batteryFloorChoices = [10, 20, 30, 50]

    private enum Keys {
        static let enabled = "glint.lidAwake.enabled"
        static let waitLimit = "glint.lidAwake.waitLimitSeconds"
        static let stallLimit = "glint.lidAwake.stallLimitSeconds"
        static let batteryFloor = "glint.lidAwake.batteryFloorPercent"
        /// Deliberately outside `glint.*`: that prefix is seeded from the
        /// production defaults into Debug, which would make a dev build clear a
        /// switch the installed build is holding.
        static let marker = "lidAwake.ownsSleepDisabled"
    }

    @Published private(set) var enabled: Bool
    @Published private(set) var authorizing = false
    @Published private(set) var authorizationFailed = false
    @Published private(set) var sudoersInstalled = false
    @Published private(set) var phase: Phase = .off
    @Published private(set) var engineStatus = LidSleepEngine.Status()

    @Published var waitLimitSeconds: Int {
        didSet {
            UserDefaults.standard.set(waitLimitSeconds, forKey: Keys.waitLimit)
            evaluate(now: Date())
        }
    }
    @Published var stallLimitSeconds: Int {
        didSet {
            UserDefaults.standard.set(stallLimitSeconds, forKey: Keys.stallLimit)
            evaluate(now: Date())
        }
    }
    @Published var batteryFloorPercent: Int {
        didSet {
            UserDefaults.standard.set(batteryFloorPercent, forKey: Keys.batteryFloor)
            evaluate(now: Date())
        }
    }

    /// True while the Mac would really stay up with the lid shut.
    var isKeepingAwake: Bool { want && engineStatus.keepingAwake }

    private weak var host: LidAwakeHost?
    private let queue = DispatchQueue(label: "app.glint.lidAwake", qos: .utility)
    private let engine: LidSleepEngine
    private var timer: Timer?
    private var want = false
    /// Stops App Nap from coalescing Glint's own timers and sockets, which keep
    /// status and Telegram alive, while the display is off.
    private var activity: NSObjectProtocol?
    private var lastProgress: [String: Date] = [:]
    private var lastCPU: [String: UInt64] = [:]
    private var lastBackgroundJob: [String: Date] = [:]
    private var lastSampleAt: Date?
    private var notifiedWaiting: Set<String> = []
    private var engagedBefore = false
    private var releasedAt: Date?
    private var timedOutPanes: [String] = []

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: Keys.enabled)
        let wait = defaults.integer(forKey: Keys.waitLimit)
        waitLimitSeconds = Self.waitLimitChoices.contains(wait) ? wait : 1_800
        let stall = defaults.integer(forKey: Keys.stallLimit)
        stallLimitSeconds = Self.stallLimitChoices.contains(stall) ? stall : 7_200
        let floor = defaults.integer(forKey: Keys.batteryFloor)
        batteryFloorPercent = Self.batteryFloorChoices.contains(floor) ? floor : 20
        engine = LidSleepEngine(
            loadMarker: { UserDefaults.standard.bool(forKey: Keys.marker) },
            saveMarker: { UserDefaults.standard.set($0, forKey: Keys.marker) })
    }

    func start(host: LidAwakeHost) {
        self.host = host
        sudoersInstalled = LidAwakeSystem.sudoersInstalled
        let engine = self.engine
        queue.async { engine.recoverAfterCrash() }
        applyEnabled()
    }

    /// Turning on may need the one-time password dialog; a Mac that already
    /// allows the two commands never shows it.
    func setEnabled(_ on: Bool) {
        authorizationFailed = false
        guard on else {
            store(enabled: false)
            return
        }
        guard !authorizing else { return }
        authorizing = true
        let engine = self.engine
        let prompt = String(localized: "Glint wants to keep agents running with the lid closed. This one-time approval only lets it switch the system's sleep setting. You can revoke it in Settings.")
        queue.async { [weak self] in
            let approved = engine.authorized(refresh: true) || engine.authorize(prompt: prompt)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.authorizing = false
                    self.sudoersInstalled = LidAwakeSystem.sudoersInstalled
                    self.authorizationFailed = !approved
                    if approved { self.store(enabled: true) }
                }
            }
        }
    }

    func revokeAuthorization() {
        store(enabled: false)
        let engine = self.engine
        queue.async { [weak self] in
            engine.revoke()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.sudoersInstalled = LidAwakeSystem.sudoersInstalled
                }
            }
        }
    }

    /// Hook events land here so a prompt sent just before closing the lid is
    /// covered at once rather than on the next tick.
    func agentActivityChanged() {
        guard enabled else { return }
        evaluate(now: Date())
    }

    /// Blocks on purpose: the switch has to be clear before the process goes.
    func shutdown() {
        timer?.invalidate()
        timer = nil
        let engine = self.engine
        queue.sync { _ = engine.reconcile(want: false) }
    }

    private func store(enabled newValue: Bool) {
        enabled = newValue
        UserDefaults.standard.set(newValue, forKey: Keys.enabled)
        applyEnabled()
    }

    private func applyEnabled() {
        timer?.invalidate()
        timer = nil
        if enabled {
            let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer.tolerance = 1
            self.timer = timer
        } else {
            releasedAt = nil
            lastProgress.removeAll()
            lastCPU.removeAll()
            lastBackgroundJob.removeAll()
            notifiedWaiting.removeAll()
        }
        evaluate(now: Date())
        syncEngine()
    }

    private func tick() {
        let now = Date()
        evaluate(now: now)
        // The tick is also the guard against other programs clearing the switch.
        if want || engineStatus.engaged { syncEngine() }
        requestSleepIfDue(now: now)
    }

    private func evaluate(now: Date) {
        let limits = LidAwakePolicy.Limits(waitLimit: TimeInterval(waitLimitSeconds),
                                           stallLimit: TimeInterval(stallLimitSeconds))
        let samples = enabled ? (host?.lidAwakePanes() ?? []) : []
        let holds = classify(samples, limits: limits, now: now)
        let block = LidAwakePolicy.block(battery: LidAwakeSystem.battery(),
                                         floorPercent: batteryFloorPercent,
                                         thermal: ProcessInfo.processInfo.thermalState)
        let active = holds.values.contains(where: \.keepsAwake)
        let newWant = enabled && active && block == nil

        let working = holds.values.filter { $0 == .working || $0 == .finishing }.count
        let waiting = holds.values.filter { $0 == .waiting }.count
        let newPhase: Phase
        if !enabled {
            newPhase = .off
        } else if active, let block {
            newPhase = .blocked(block)
        } else if working > 0 {
            newPhase = .working(working)
        } else if waiting > 0 {
            newPhase = .waiting(waiting)
        } else {
            newPhase = .standby
        }
        if phase != newPhase { phase = newPhase }

        notifyWaiting(holds)
        timedOutPanes = holds.filter { $0.value == .waitExpired || $0.value == .stalled }.map(\.key)

        guard newWant != want else { return }
        want = newWant
        updateActivity()
        syncEngine()
    }

    private func classify(_ samples: [LidAwakePaneSample],
                          limits: LidAwakePolicy.Limits,
                          now: Date) -> [String: LidAwakePolicy.PaneHold] {
        let elapsed = lastSampleAt.map { now.timeIntervalSince($0) } ?? 0
        lastSampleAt = now
        var holds: [String: LidAwakePolicy.PaneHold] = [:]
        for sample in samples {
            if let cpu = sample.childCPUNanoseconds {
                // A finished child drops out of the total, so a fall isn't work.
                let delta = lastCPU[sample.handle].map { cpu > $0 ? cpu - $0 : 0 } ?? 0
                if LidAwakePolicy.madeProgress(cpuDelta: delta, elapsed: elapsed) {
                    lastProgress[sample.handle] = now
                }
                lastCPU[sample.handle] = cpu
            } else {
                lastCPU.removeValue(forKey: sample.handle)
            }
            if sample.backgroundJobRunning { lastBackgroundJob[sample.handle] = now }
            holds[sample.handle] = LidAwakePolicy.classify(
                status: sample.status,
                updatedAt: sample.updatedAt,
                lastProgress: lastProgress[sample.handle] ?? sample.updatedAt,
                agentAlive: sample.agentAlive,
                backgroundJob: sample.backgroundJobRunning,
                lastBackgroundJob: lastBackgroundJob[sample.handle],
                now: now,
                limits: limits)
        }
        lastProgress = lastProgress.filter { holds[$0.key] != nil }
        lastCPU = lastCPU.filter { holds[$0.key] != nil }
        lastBackgroundJob = lastBackgroundJob.filter { holds[$0.key] != nil }
        return holds
    }

    private func updateActivity() {
        if want, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Agents running with the lid closed")
        } else if !want, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
    }

    private func syncEngine() {
        let want = self.want
        let engine = self.engine
        queue.async { [weak self] in
            let status = engine.reconcile(want: want)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(status, wanted: want) }
            }
        }
    }

    private func apply(_ status: LidSleepEngine.Status, wanted: Bool) {
        if engineStatus != status { engineStatus = status }
        if engagedBefore && !status.engaged && !wanted {
            releasedAt = Date()
            notifyReleased()
        }
        if wanted { releasedAt = nil }
        engagedBefore = status.engaged
    }

    private func requestSleepIfDue(now: Date) {
        guard let releasedAt,
              now.timeIntervalSince(releasedAt) >= LidAwakePolicy.sleepDelay else { return }
        let lidClosed = LidAwakeSystem.lidClosed()
        // Lid open: the Mac's normal behaviour takes over from here.
        guard lidClosed == true else {
            self.releasedAt = nil
            return
        }
        let hasExternalDisplay = LidAwakeSystem.hasExternalDisplay()
        let userIdle = LidAwakeSystem.secondsSinceUserInput()
        let engine = self.engine
        queue.async { [weak self] in
            guard LidAwakePolicy.shouldSleepNow(lidClosed: lidClosed,
                                                sleepDisabled: engine.sleepDisabledRightNow(),
                                                hasExternalDisplay: hasExternalDisplay,
                                                userIdle: userIdle) else { return }
            engine.sleepNow()
            DispatchQueue.main.async {
                // Otherwise a dark wake would ask for sleep all over again.
                MainActor.assumeIsolated { self?.releasedAt = nil }
            }
        }
    }

    // MARK: Telegram

    /// Answers "the lid is shut, so I can't see it's waiting for me". One-way:
    /// these prompts can't be answered from the phone.
    private func notifyWaiting(_ holds: [String: LidAwakePolicy.PaneHold]) {
        let waiting = Set(holds.filter { $0.value == .waiting }.keys)
        notifiedWaiting.formIntersection(waiting)
        guard !waiting.isEmpty, TelegramBridge.shared.canPush,
              LidAwakeSystem.lidClosed() == true else { return }
        let minutes = waitLimitSeconds / 60
        for handle in waiting.subtracting(notifiedWaiting) {
            notifiedWaiting.insert(handle)
            let title = host?.confirmationTitle(forPane: handle) ?? "Glint"
            TelegramBridge.shared.post(String(format: String(localized: "%1$@ is waiting for your answer. Your Mac sleeps if nobody replies within %2$lld minutes."),
                                              title, minutes))
        }
    }

    private func notifyReleased() {
        guard TelegramBridge.shared.canPush, LidAwakeSystem.lidClosed() == true,
              !timedOutPanes.isEmpty else { return }
        let titles = timedOutPanes.compactMap { host?.confirmationTitle(forPane: $0) }
        TelegramBridge.shared.post(String(format: String(localized: "%@ made no progress, so your Mac is going to sleep. Open the lid to continue."),
                                          titles.isEmpty ? "Glint" : titles.joined(separator: ", ")))
    }

    // MARK: Display

    var statusText: String {
        if authorizing { return String(localized: "Waiting for system approval…") }
        if authorizationFailed {
            return String(localized: "Not approved, so the Mac still sleeps when the lid closes.")
        }
        switch engineStatus.failure {
        case .notAuthorized:
            return String(localized: "The system approval is gone. Turn this off and on again to restore it.")
        case .switchFailed:
            return String(localized: "Couldn't change the system's sleep setting.")
        case .watcherFailed:
            return String(localized: "Safety watcher didn't start, so the Mac still sleeps when the lid closes.")
        case nil:
            break
        }
        switch phase {
        case .off:
            return String(localized: "Off. The Mac sleeps when the lid closes.")
        case .standby:
            return String(localized: "Ready. Nothing needs the Mac to stay awake right now.")
        case let .working(count):
            return String(format: String(localized: "Keeping the Mac awake for %lld running agent(s)."), count)
        case let .waiting(count):
            return String(format: String(localized: "%lld agent(s) waiting for you. The Mac sleeps when the time limit is reached."), count)
        case .blocked(.battery):
            return String(localized: "Battery is low, so the Mac can sleep.")
        case .blocked(.thermal):
            return String(localized: "The Mac is too hot, so it can sleep.")
        }
    }

    var statusIsProblem: Bool {
        if authorizationFailed || engineStatus.failure != nil { return true }
        if case .blocked = phase { return true }
        return false
    }

    /// Non-nil once another app has fought the switch, so a surprise sleep has
    /// an explanation.
    var overrideText: String? {
        guard engineStatus.overrides > 0 else { return nil }
        let names = engineStatus.lastCulprits.isEmpty
            ? String(localized: "unknown")
            : engineStatus.lastCulprits.joined(separator: ", ")
        return String(format: String(localized: "Another app cleared the sleep setting %1$lld time(s) and Glint restored it. Running: %2$@."),
                      engineStatus.overrides, names)
    }
}
