import XCTest
@testable import Glint

final class GrokHookInstallerTests: XCTestCase {

    private var tempDir: URL!
    private var hooksURL: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glint-grok-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        hooksURL = tempDir.appendingPathComponent(GrokHookInstaller.hooksFileName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// No hooks file → not installed. Uses an injected temp path so the
    /// result never depends on whether the dev machine actually runs Grok.
    func testNotInstalledWhenFileMissing() {
        XCTAssertFalse(GrokHookInstaller.isInstalled(hooksURL: hooksURL))
    }

    /// Registered events drive the sidebar status machine. PermissionRequest
    /// is intentionally omitted for v1 (Grok has PermissionDenied, not the
    /// Claude-style approval gate).
    func testHookEventsMatchGrokSupportedSubset() {
        XCTAssertEqual(
            GrokHookInstaller.hookEvents,
            [
                "SessionStart",
                "UserPromptSubmit",
                "PreToolUse",
                "PostToolUse",
                "Notification",
                "PreCompact",
                "Stop",
                "StopFailure",
            ]
        )
        XCTAssertFalse(GrokHookInstaller.hookEvents.contains("PermissionRequest"))
    }

    /// Merging creates the file, registers one entry per supported event, and
    /// tags each command with the `grok` agent kind so panes are attributed
    /// correctly (not mis-labeled as Claude).
    func testMergeCreatesHooksFileAndRegistersEvents() throws {
        GrokHookInstaller.mergeGrokHooks(scriptPath: "/tmp/glint-report.sh", hooksURL: hooksURL)

        XCTAssertTrue(GrokHookInstaller.isInstalled(hooksURL: hooksURL))

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as? [String: Any]
        let hooks = (root?["hooks"] as? [String: Any]) ?? [:]
        XCTAssertEqual(Set(hooks.keys), Set(GrokHookInstaller.hookEvents))

        let stop = (hooks["Stop"] as? [Any])?.first as? [String: Any]
        let inner = (stop?["hooks"] as? [[String: Any]])?.first
        XCTAssertEqual(inner?["command"] as? String, "/tmp/glint-report.sh Stop grok")
        // Lifecycle events reject a matcher in Grok's schema.
        XCTAssertNil(stop?["matcher"])
    }

    /// Tool-boundary events include a matcher so Grok accepts the entry.
    func testToolEventsCarryMatcher() throws {
        GrokHookInstaller.mergeGrokHooks(scriptPath: "/tmp/glint-report.sh", hooksURL: hooksURL)

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as? [String: Any]
        let hooks = (root?["hooks"] as? [String: Any]) ?? [:]
        for event in ["PreToolUse", "PostToolUse", "Notification"] {
            let group = (hooks[event] as? [Any])?.first as? [String: Any]
            XCTAssertEqual(group?["matcher"] as? String, ".*",
                           "\(event) should carry matcher \".*\"")
        }
    }

    /// Installing twice is idempotent — no duplicate Glint entries pile up.
    func testMergeIsIdempotent() throws {
        GrokHookInstaller.mergeGrokHooks(scriptPath: "/tmp/glint-report.sh", hooksURL: hooksURL)
        GrokHookInstaller.mergeGrokHooks(scriptPath: "/tmp/glint-report.sh", hooksURL: hooksURL)

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as? [String: Any]
        let stop = (root?["hooks"] as? [String: Any])?["Stop"] as? [Any]
        XCTAssertEqual(stop?.count, 1, "duplicate Glint hook entry after second install")
    }

    /// Uninstall removes our owned file when it only contains Glint hooks.
    func testUninstallRemovesOwnedFile() throws {
        GrokHookInstaller.mergeGrokHooks(scriptPath: "/tmp/glint-report.sh", hooksURL: hooksURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hooksURL.path))
        XCTAssertTrue(GrokHookInstaller.isInstalled(hooksURL: hooksURL))

        GrokHookInstaller.uninstall(hooksURL: hooksURL)

        XCTAssertFalse(GrokHookInstaller.isInstalled(hooksURL: hooksURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hooksURL.path),
                       "owned glint-status.json should be deleted when only ours")
    }

    /// When the file also holds non-Glint entries, uninstall strips only ours.
    func testUninstallStripsOursButKeepsForeignHooks() throws {
        // Seed a file that already has a foreign Stop hook.
        let seed: [String: Any] = [
            "hooks": [
                "Stop": [[
                    "hooks": [[
                        "type": "command",
                        "command": "/usr/bin/true",
                    ]],
                ]],
            ],
        ]
        let seedData = try JSONSerialization.data(withJSONObject: seed, options: [.prettyPrinted])
        try seedData.write(to: hooksURL)

        GrokHookInstaller.mergeGrokHooks(scriptPath: "/tmp/glint-report.sh", hooksURL: hooksURL)
        XCTAssertTrue(GrokHookInstaller.isInstalled(hooksURL: hooksURL))

        GrokHookInstaller.uninstall(hooksURL: hooksURL)

        XCTAssertFalse(GrokHookInstaller.isInstalled(hooksURL: hooksURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hooksURL.path),
                      "file should remain when foreign hooks are present")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as? [String: Any]
        let stop = (root?["hooks"] as? [String: Any])?["Stop"] as? [Any]
        XCTAssertEqual(stop?.count, 1)
        let inner = ((stop?.first as? [String: Any])?["hooks"] as? [[String: Any]])?.first
        XCTAssertEqual(inner?["command"] as? String, "/usr/bin/true")
    }
}
