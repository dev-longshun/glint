import XCTest
@testable import Glint

/// Fork: persisted shape of the bot group flag and the per-pane startup
/// command. Both are additive keys — saves written before the feature must
/// keep loading, and workspaces that don't use it must stay byte-clean.
final class BotWorkspaceTests: XCTestCase {

    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try (JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func testPaneWithoutStartupCommandOmitsKey() throws {
        let pane = Pane(id: PaneID(value: 0), title: "zsh")
        XCTAssertNil(try object(pane)["startupCommand"])
    }

    func testPaneStartupCommandRoundTrips() throws {
        var pane = Pane(id: PaneID(value: 0), title: "zsh")
        pane.startupCommand = "tmux new-session -A -s bot"
        let decoded = try JSONDecoder().decode(Pane.self, from: JSONEncoder().encode(pane))
        XCTAssertEqual(decoded.startupCommand, "tmux new-session -A -s bot")
    }

    func testPaneFromOlderSaveHasNoStartupCommand() throws {
        let json = #"{"id": {"value": 3}, "title": "zsh", "workingDirectory": "/tmp"}"#
        let pane = try JSONDecoder().decode(Pane.self, from: Data(json.utf8))
        XCTAssertNil(pane.startupCommand)
    }

    func testWorkspaceBotFlagRoundTripsAndIsOmittedWhenFalse() throws {
        var ws = Workspace.fresh(name: "life", accentHex: "5E5CE6", symbol: "•")
        XCTAssertFalse(ws.isBot)
        XCTAssertNil(try object(ws)["bot"])

        ws.isBot = true
        XCTAssertEqual(try object(ws)["bot"] as? Bool, true)
        let decoded = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(ws))
        XCTAssertTrue(decoded.isBot)
    }

    func testStartupInputIsTrimmedAndNewlineTerminated() {
        XCTAssertEqual(WorkspaceStore.startupInput(from: "  tmux attach -t tg \n"), "tmux attach -t tg\n")
        XCTAssertNil(WorkspaceStore.startupInput(from: "   \n"))
        XCTAssertNil(WorkspaceStore.startupInput(from: nil))
    }
}
