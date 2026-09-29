import XCTest
@testable import Glint

final class AgyHookInstallerTests: XCTestCase {

    private var tempDir: URL!
    private var hooksURL: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glint-agy-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        hooksURL = tempDir.appendingPathComponent("hooks.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testNotInstalledWhenHooksMissing() {
        XCTAssertFalse(AgyHookInstaller.isInstalled(hooksURL: hooksURL))
    }

    func testHookEventsCoverStatusMachineAndAgySurface() {
        XCTAssertEqual(
            AgyHookInstaller.hookEvents,
            [
                "PreInvocation",
                "PreToolUse",
                "PostToolUse",
                "Stop",
            ]
        )
        // agy has no permission-prompt hook (approvals are TUI-native) and no
        // UserPromptSubmit — the reporter remaps the turn's first
        // PreInvocation (invocationNum == 1) to UserPromptSubmit instead.
        XCTAssertFalse(AgyHookInstaller.hookEvents.contains("PermissionRequest"))
        XCTAssertFalse(AgyHookInstaller.hookEvents.contains("UserPromptSubmit"))
    }

    /// Tool events take grouped entries (matcher + inner hooks); lifecycle
    /// events take a flat handler list — per agy's built-in hooks doc.
    func testMergeUsesGroupedToolEntriesAndFlatLifecycleEntries() throws {
        AgyHookInstaller.mergeAgyHooks(scriptPath: "/tmp/glint-report.sh", hooksURL: hooksURL)

        XCTAssertTrue(AgyHookInstaller.isInstalled(hooksURL: hooksURL))

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as? [String: Any]
        )
        let ours = try XCTUnwrap(root[AgyHookInstaller.entryName] as? [String: Any])
        XCTAssertEqual(Set(ours.keys), Set(AgyHookInstaller.hookEvents))

        // Tool events: {matcher: "*", hooks: [{type, command, timeout}]}
        let preTool = try XCTUnwrap((ours["PreToolUse"] as? [Any])?.first as? [String: Any])
        XCTAssertEqual(preTool["matcher"] as? String, "*")
        let inner = try XCTUnwrap((preTool["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(inner["command"] as? String, "/tmp/glint-report.sh PreToolUse agy")
        XCTAssertEqual(inner["type"] as? String, "command")

        // Lifecycle events: flat {type, command, timeout} — no matcher key.
        let stop = try XCTUnwrap((ours["Stop"] as? [Any])?.first as? [String: Any])
        XCTAssertEqual(stop["command"] as? String, "/tmp/glint-report.sh Stop agy")
        XCTAssertNil(stop["matcher"])
    }

    /// The shared hooks.json may already carry the user's own named hooks —
    /// merging must preserve them untouched.
    func testMergePreservesForeignNamedHooks() throws {
        let foreign: [String: Any] = [
            "lint-checker": [
                "PostToolUse": [
                    ["matcher": "run_command",
                     "hooks": [["type": "command", "command": "./lint.sh"]]]
                ]
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: foreign)
        try data.write(to: hooksURL, options: [.atomic])

        AgyHookInstaller.mergeAgyHooks(scriptPath: "/tmp/glint-report.sh", hooksURL: hooksURL)

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as? [String: Any]
        )
        XCTAssertNotNil(root["lint-checker"], "foreign named hook must survive the merge")
        XCTAssertNotNil(root[AgyHookInstaller.entryName])
    }

    func testMergeIsIdempotent() throws {
        AgyHookInstaller.mergeAgyHooks(scriptPath: "/tmp/glint-report.sh", hooksURL: hooksURL)
        let first = try Data(contentsOf: hooksURL)
        AgyHookInstaller.mergeAgyHooks(scriptPath: "/tmp/glint-report.sh", hooksURL: hooksURL)
        let second = try Data(contentsOf: hooksURL)
        XCTAssertEqual(first, second)
    }

    /// Reinstall after the script path moved (e.g. home relocation) rewrites
    /// our entry with the new path while keeping foreign hooks.
    func testMergeUpdatesStaleScriptPath() throws {
        AgyHookInstaller.mergeAgyHooks(scriptPath: "/old/glint-report.sh", hooksURL: hooksURL)
        AgyHookInstaller.mergeAgyHooks(scriptPath: "/new/glint-report.sh", hooksURL: hooksURL)

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as? [String: Any]
        )
        let ours = try XCTUnwrap(root[AgyHookInstaller.entryName] as? [String: Any])
        let stop = try XCTUnwrap((ours["Stop"] as? [Any])?.first as? [String: Any])
        XCTAssertEqual(stop["command"] as? String, "/new/glint-report.sh Stop agy")
    }

    /// Uninstall removes ONLY Glint's named entry; a sibling hook survives
    /// and the file stays on disk.
    func testUninstallRemovesOnlyGlintEntry() throws {
        let foreign: [String: Any] = ["mine": ["Stop": [["type": "command", "command": "true"]]]]
        try JSONSerialization.data(withJSONObject: foreign).write(to: hooksURL, options: [.atomic])
        AgyHookInstaller.mergeAgyHooks(scriptPath: "/tmp/glint-report.sh", hooksURL: hooksURL)

        AgyHookInstaller.uninstall(hooksURL: hooksURL)

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as? [String: Any]
        )
        XCTAssertNil(root[AgyHookInstaller.entryName])
        XCTAssertNotNil(root["mine"])
        XCTAssertFalse(AgyHookInstaller.isInstalled(hooksURL: hooksURL))
    }

    /// When Glint's entry was the only content, uninstall deletes the now
    /// empty document instead of leaving `{}` behind.
    func testUninstallDeletesEmptyDocument() throws {
        AgyHookInstaller.mergeAgyHooks(scriptPath: "/tmp/glint-report.sh", hooksURL: hooksURL)

        AgyHookInstaller.uninstall(hooksURL: hooksURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: hooksURL.path))
    }

    // MARK: - kind resolution + restore command

    @MainActor
    func testAgentKindResolvesAgyProcessNames() {
        XCTAssertEqual(WorkspaceStore.agentKind(named: "agy"), .agy)
        XCTAssertEqual(WorkspaceStore.agentKind(named: "/Users/xin/.local/bin/agy"), .agy)
        XCTAssertEqual(WorkspaceStore.agentKind(named: "antigravity"), .agy)
        // Three letters — no substring stealing.
        XCTAssertNil(WorkspaceStore.agentKind(named: "imagyk"))
        // gemini-cli must NOT resolve as agy (shared ~/.gemini root).
        XCTAssertNil(WorkspaceStore.agentKind(named: "gemini"))
    }

    func testRestoreCommandUsesConversationResume() {
        XCTAssertEqual(PaneAgentKind.agy.restoreCommand(sessionId: nil), "agy --continue\n")
        XCTAssertEqual(
            PaneAgentKind.agy.restoreCommand(sessionId: "ec33ebf9-0cba-4100-8142-c61503f6c587"),
            "agy --conversation ec33ebf9-0cba-4100-8142-c61503f6c587\n"
        )
        // Non-whitelisted ids degrade to the fallback instead of reaching the TTY.
        XCTAssertEqual(PaneAgentKind.agy.restoreCommand(sessionId: "evil'id"), "agy --continue\n")
    }
}
