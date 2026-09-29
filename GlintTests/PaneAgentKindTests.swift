import XCTest
@testable import Glint

final class PaneAgentKindTests: XCTestCase {

    // MARK: displayName

    func testClaudeDisplayName() {
        XCTAssertEqual(PaneAgentKind.claude.displayName, "Claude")
    }

    func testCodexDisplayName() {
        XCTAssertEqual(PaneAgentKind.codex.displayName, "Codex")
    }

    func testOpenCodeDisplayName() {
        XCTAssertEqual(PaneAgentKind.opencode.displayName, "OpenCode")
    }

    func testDevinDisplayName() {
        XCTAssertEqual(PaneAgentKind.devin.displayName, "Devin")
    }

    func testOmpDisplayName() {
        XCTAssertEqual(PaneAgentKind.omp.displayName, "OMP")
    }

    func testGrokDisplayName() {
        XCTAssertEqual(PaneAgentKind.grok.displayName, "Grok")
    }

    // MARK: iconKind

    func testClaudeIconKind() {
        XCTAssertTrue(isIconKind(PaneAgentKind.claude.iconKind, .claude))
    }

    func testCodexIconKind() {
        XCTAssertTrue(isIconKind(PaneAgentKind.codex.iconKind, .codex))
    }

    func testOpenCodeIconKind() {
        XCTAssertTrue(isIconKind(PaneAgentKind.opencode.iconKind, .opencode))
    }

    func testDevinIconKind() {
        XCTAssertTrue(isIconKind(PaneAgentKind.devin.iconKind, .devin))
    }

    func testOmpIconKind() {
        XCTAssertTrue(isIconKind(PaneAgentKind.omp.iconKind, .omp))
    }

    func testGrokIconKind() {
        XCTAssertTrue(isIconKind(PaneAgentKind.grok.iconKind, .grok))
    }

    // MARK: isValid(sessionId:)

    func testValidSessionIdAcceptsAlphanumericAndPunct() {
        XCTAssertTrue(PaneAgentKind.isValid(sessionId: "01HK2X3F4Y5Z6A7B"))
        XCTAssertTrue(PaneAgentKind.isValid(sessionId: "abc_def-123"))
        XCTAssertTrue(PaneAgentKind.isValid(sessionId: "A"))
    }

    func testValidSessionIdRejectsEmpty() {
        XCTAssertFalse(PaneAgentKind.isValid(sessionId: ""))
    }

    func testValidSessionIdRejectsTooLong() {
        let s = String(repeating: "a", count: PaneAgentKind.sessionIdMaxLength + 1)
        XCTAssertFalse(PaneAgentKind.isValid(sessionId: s))
    }

    func testValidSessionIdAcceptsMaxLength() {
        let s = String(repeating: "a", count: PaneAgentKind.sessionIdMaxLength)
        XCTAssertTrue(PaneAgentKind.isValid(sessionId: s))
    }

    func testValidSessionIdRejectsDisallowedChars() {
        // Anything that would smuggle a second shell token must fail.
        XCTAssertFalse(PaneAgentKind.isValid(sessionId: "a b"))
        XCTAssertFalse(PaneAgentKind.isValid(sessionId: "a;b"))
        XCTAssertFalse(PaneAgentKind.isValid(sessionId: "a\nb"))
        XCTAssertFalse(PaneAgentKind.isValid(sessionId: "a/b"))
        XCTAssertFalse(PaneAgentKind.isValid(sessionId: "a.b"))
        XCTAssertFalse(PaneAgentKind.isValid(sessionId: "a\"b"))
    }

    // MARK: restoreCommand

    func testRestoreCommandWithValidIdUsesResumeForm() {
        XCTAssertEqual(PaneAgentKind.claude.restoreCommand(sessionId: "abc-123"),
                       "claude --resume abc-123\n")
        XCTAssertEqual(PaneAgentKind.codex.restoreCommand(sessionId: "abc-123"),
                       "codex resume abc-123\n")
        XCTAssertEqual(PaneAgentKind.opencode.restoreCommand(sessionId: "abc-123"),
                       "opencode --session abc-123\n")
        XCTAssertEqual(PaneAgentKind.devin.restoreCommand(sessionId: "abc-123"),
                       "devin --resume abc-123\n")
        XCTAssertEqual(PaneAgentKind.omp.restoreCommand(sessionId: "abc-123"),
                       "omp -r abc-123\n")
        XCTAssertEqual(PaneAgentKind.grok.restoreCommand(sessionId: "abc-123"),
                       "grok --resume abc-123\n")
    }

    func testRestoreCommandNilFallsBackToContinue() {
        XCTAssertEqual(PaneAgentKind.claude.restoreCommand(sessionId: nil),
                       "claude --continue\n")
        XCTAssertEqual(PaneAgentKind.codex.restoreCommand(sessionId: nil),
                       "codex resume --last\n")
        XCTAssertEqual(PaneAgentKind.opencode.restoreCommand(sessionId: nil),
                       "opencode --continue\n")
        XCTAssertEqual(PaneAgentKind.devin.restoreCommand(sessionId: nil),
                       "devin --continue\n")
        XCTAssertEqual(PaneAgentKind.omp.restoreCommand(sessionId: nil),
                       "omp -c\n")
        XCTAssertEqual(PaneAgentKind.grok.restoreCommand(sessionId: nil),
                       "grok --continue\n")
    }

    func testRestoreCommandRejectsInjectedIdAndDowngradesToContinue() {
        // Defense in depth: an id that bypassed any outer gate must NOT be
        // interpolated into the TTY string. Caller forgets validation → we
        // still emit the safe fallback rather than a primed shell.
        let injected = "abc\n; rm -rf /tmp/nope\n"
        XCTAssertEqual(PaneAgentKind.claude.restoreCommand(sessionId: injected),
                       "claude --continue\n")
        XCTAssertEqual(PaneAgentKind.codex.restoreCommand(sessionId: injected),
                       "codex resume --last\n")
    }

    // MARK: restoreCommand — non-default Codex Home prefix

    func testRestoreCommandCodexHomePrefixesResume() {
        // A non-default-home Codex pane must re-prefix its resume command with
        // the same CODEX_HOME it launched under, or restart resumes against
        // ~/.codex where the session doesn't exist (#45 for multi-home).
        let home = "/Users/test/codex-secondary"
        XCTAssertEqual(PaneAgentKind.codex.restoreCommand(sessionId: "abc-123", codexHome: home),
                       "CODEX_HOME='\(home)' codex resume abc-123\n")
        // Fallback form (--last) carries the prefix too.
        XCTAssertEqual(PaneAgentKind.codex.restoreCommand(sessionId: nil, codexHome: home),
                       "CODEX_HOME='\(home)' codex resume --last\n")
    }

    func testRestoreCommandCodexHomeIgnoredForDefaultAndOtherKinds() {
        // Default home (nil) ⇒ no prefix; other agents ignore the home entirely.
        XCTAssertEqual(PaneAgentKind.codex.restoreCommand(sessionId: "abc-123", codexHome: nil),
                       "codex resume abc-123\n")
        XCTAssertEqual(PaneAgentKind.claude.restoreCommand(sessionId: "abc-123", codexHome: "/x"),
                       "claude --resume abc-123\n")
    }

    // MARK: permissionFlags(fromArguments:)

    func testPermissionFlagsFromShellAliases() {
        // cc / cx / gk as they arrive in argv (argv[0] already dropped). The
        // npm codex shim puts its bin path first; it must be skipped.
        XCTAssertEqual(PaneAgentKind.claude.permissionFlags(fromArguments: ["--dangerously-skip-permissions"]),
                       ["--dangerously-skip-permissions"])
        XCTAssertEqual(PaneAgentKind.codex.permissionFlags(fromArguments: [
            "/Users/x/.npm-global/bin/codex", "--dangerously-bypass-approvals-and-sandbox",
        ]), ["--dangerously-bypass-approvals-and-sandbox"])
        XCTAssertEqual(PaneAgentKind.grok.permissionFlags(fromArguments: ["--always-approve"]),
                       ["--always-approve"])
    }

    func testPermissionFlagsCanonicalizesValuedAndShortForms() {
        XCTAssertEqual(PaneAgentKind.claude.permissionFlags(fromArguments: ["--permission-mode=bypassPermissions"]),
                       ["--permission-mode", "bypassPermissions"])
        XCTAssertEqual(PaneAgentKind.codex.permissionFlags(fromArguments: ["-a", "never", "-s", "danger-full-access"]),
                       ["--ask-for-approval", "never", "--sandbox", "danger-full-access"])
        XCTAssertEqual(PaneAgentKind.grok.permissionFlags(fromArguments: ["--sandbox", "strict", "--permission-mode", "auto"]),
                       ["--sandbox", "strict", "--permission-mode", "auto"])
    }

    func testPermissionFlagsIgnoresNonWhitelistedArgs() {
        // A restored pane's argv carries its resume args, and users pass
        // models / prompts / config overrides — none of that may be captured.
        XCTAssertEqual(PaneAgentKind.claude.permissionFlags(fromArguments: [
            "--model", "opus", "--dangerously-skip-permissions", "--resume", "abc-123", "fix the bug",
        ]), ["--dangerously-skip-permissions"])
        XCTAssertEqual(PaneAgentKind.codex.permissionFlags(fromArguments: [
            "resume", "--dangerously-bypass-approvals-and-sandbox", "abc-123", "-c", "model=\"o3\"", "--full-auto",
        ]), ["--dangerously-bypass-approvals-and-sandbox"])
    }

    func testPermissionFlagsDropsInvalidOrMissingValues() {
        XCTAssertEqual(PaneAgentKind.claude.permissionFlags(fromArguments: ["--permission-mode", "x;rm -rf ~"]), [])
        XCTAssertEqual(PaneAgentKind.claude.permissionFlags(fromArguments: ["--permission-mode"]), [])
        // A missing value must not swallow the next flag.
        XCTAssertEqual(PaneAgentKind.grok.permissionFlags(fromArguments: ["--sandbox", "--always-approve"]),
                       ["--always-approve"])
        // Boolean flags don't take an inline value.
        XCTAssertEqual(PaneAgentKind.claude.permissionFlags(fromArguments: ["--dangerously-skip-permissions=1"]), [])
    }

    func testPermissionFlagsStopsAtDoubleDashAndDedupes() {
        XCTAssertEqual(PaneAgentKind.claude.permissionFlags(fromArguments: [
            "--dangerously-skip-permissions", "--dangerously-skip-permissions", "--", "--permission-mode", "plan",
        ]), ["--dangerously-skip-permissions"])
    }

    func testPermissionFlagsStayWithinEachAgentsWhitelist() {
        XCTAssertEqual(PaneAgentKind.claude.permissionFlags(fromArguments: ["--always-approve"]), [])
        XCTAssertEqual(PaneAgentKind.grok.permissionFlags(fromArguments: ["--dangerously-skip-permissions"]), [])
        XCTAssertEqual(PaneAgentKind.opencode.permissionFlags(fromArguments: ["--dangerously-skip-permissions"]), [])
    }

    func testPermissionFlagsIsIdempotent() {
        // restoreCommand re-filters persisted flags through the same function.
        let once = PaneAgentKind.codex.permissionFlags(fromArguments: ["-s", "workspace-write", "--approve-for-me"])
        XCTAssertEqual(PaneAgentKind.codex.permissionFlags(fromArguments: once), once)
    }

    // MARK: restoreCommand — launch flags

    func testRestoreCommandReplaysLaunchFlags() {
        XCTAssertEqual(PaneAgentKind.claude.restoreCommand(sessionId: "abc-123", launchFlags: ["--dangerously-skip-permissions"]),
                       "claude --dangerously-skip-permissions --resume abc-123\n")
        XCTAssertEqual(PaneAgentKind.claude.restoreCommand(sessionId: nil, launchFlags: ["--dangerously-skip-permissions"]),
                       "claude --dangerously-skip-permissions --continue\n")
        XCTAssertEqual(PaneAgentKind.codex.restoreCommand(sessionId: "abc-123", launchFlags: ["--dangerously-bypass-approvals-and-sandbox"]),
                       "codex resume --dangerously-bypass-approvals-and-sandbox abc-123\n")
        XCTAssertEqual(PaneAgentKind.codex.restoreCommand(sessionId: nil, launchFlags: ["--dangerously-bypass-approvals-and-sandbox"]),
                       "codex resume --dangerously-bypass-approvals-and-sandbox --last\n")
        XCTAssertEqual(PaneAgentKind.grok.restoreCommand(sessionId: "abc-123", launchFlags: ["--always-approve"]),
                       "grok --always-approve --resume abc-123\n")
        XCTAssertEqual(PaneAgentKind.grok.restoreCommand(sessionId: nil, launchFlags: ["--always-approve"]),
                       "grok --always-approve --continue\n")
    }

    func testRestoreCommandCodexHomeAndFlagsCompose() {
        let home = "/Users/test/codex-secondary"
        XCTAssertEqual(PaneAgentKind.codex.restoreCommand(sessionId: "abc-123", codexHome: home,
                                                          launchFlags: ["--sandbox", "danger-full-access"]),
                       "CODEX_HOME='\(home)' codex resume --sandbox danger-full-access abc-123\n")
    }

    func testRestoreCommandDropsTamperedLaunchFlags() {
        // A hand-edited or corrupt state.json must not get arbitrary text onto
        // the shell; kinds without a whitelist ignore flags entirely.
        let tampered = ["--dangerously-skip-permissions; rm -rf ~", "--permission-mode", "plan\nrm", "--evil"]
        XCTAssertEqual(PaneAgentKind.claude.restoreCommand(sessionId: "abc-123", launchFlags: tampered),
                       "claude --resume abc-123\n")
        XCTAssertEqual(PaneAgentKind.opencode.restoreCommand(sessionId: "abc-123", launchFlags: ["--dangerously-skip-permissions"]),
                       "opencode --session abc-123\n")
    }

    // MARK: always skip permission prompts on resume

    func testSkipPermissionFlagsSurviveEachAgentsWhitelist() throws {
        // restoreCommand re-filters flags; a forced flag it dropped would
        // silently resume in the CLI's default mode.
        for kind in [PaneAgentKind.claude, .codex, .grok] {
            let forced = try XCTUnwrap(kind.skipPermissionFlags)
            XCTAssertEqual(kind.permissionFlags(fromArguments: forced), forced, "\(kind)")
        }
        for kind in [PaneAgentKind.opencode, .devin, .omp, .pi, .agy] {
            XCTAssertNil(kind.skipPermissionFlags, "\(kind)")
        }
    }

    func testRestoreLaunchFlagsAlwaysSkipReplacesRecordedFlags() {
        let recorded = ["--ask-for-approval", "on-request", "--sandbox", "workspace-write"]
        XCTAssertEqual(WorkspaceStore.restoreLaunchFlags(for: .codex, captured: recorded, alwaysSkip: true),
                       ["--dangerously-bypass-approvals-and-sandbox"])
        // Nothing recorded (state saved by a build without launchFlags).
        XCTAssertEqual(WorkspaceStore.restoreLaunchFlags(for: .claude, captured: [], alwaysSkip: true),
                       ["--dangerously-skip-permissions"])
        XCTAssertEqual(WorkspaceStore.restoreLaunchFlags(for: .grok, captured: [], alwaysSkip: true),
                       ["--always-approve"])
    }

    func testRestoreLaunchFlagsKeepsRecordedFlagsWhenOffOrUnsupported() {
        let recorded = ["--permission-mode", "plan"]
        XCTAssertEqual(WorkspaceStore.restoreLaunchFlags(for: .claude, captured: recorded, alwaysSkip: false), recorded)
        XCTAssertEqual(WorkspaceStore.restoreLaunchFlags(for: .claude, captured: [], alwaysSkip: false), [])
        XCTAssertEqual(WorkspaceStore.restoreLaunchFlags(for: .opencode, captured: [], alwaysSkip: true), [])
    }

    func testAlwaysSkipYieldsSkipPermissionResumeCommand() {
        let flags = WorkspaceStore.restoreLaunchFlags(for: .claude, captured: [], alwaysSkip: true)
        XCTAssertEqual(PaneAgentKind.claude.restoreCommand(sessionId: "abc-123", launchFlags: flags),
                       "claude --dangerously-skip-permissions --resume abc-123\n")
    }

    // MARK: helpers

    /// WorkspaceIconKind isn't Equatable, so compare by matching the expected
    /// case via a switch.
    private func isIconKind(_ actual: WorkspaceIconKind, _ expected: WorkspaceIconKind) -> Bool {
        switch (actual, expected) {
        case (.claude, .claude), (.codex, .codex),
             (.opencode, .opencode), (.devin, .devin), (.omp, .omp), (.grok, .grok),
             (.shell, .shell), (.ssh, .ssh), (.vim, .vim),
             (.python, .python), (.node, .node), (.git, .git):
            return true
        default:
            return false
        }
    }
}
