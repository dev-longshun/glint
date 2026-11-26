import XCTest
@testable import Glint

/// Fork: per-bot `api.env` (see `BotAPIConfig`). The launch script
/// (`~/.claude/channels/tgbots/api-env.sh`) parses the same file, so these
/// pin the shape both sides agree on.
final class BotAPIConfigTests: XCTestCase {

    func testBotNameFromAttachCommand() {
        XCTAssertEqual(BotRegistry.botName(fromStartupCommand: "~/.claude/channels/tgbots/glint-attach.sh ledger"), "ledger")
        XCTAssertEqual(BotRegistry.botName(fromStartupCommand: "  /x/glint-attach.sh   campus  "), "campus")
        XCTAssertNil(BotRegistry.botName(fromStartupCommand: "tmux new-session -A -s bot"))
        XCTAssertNil(BotRegistry.botName(fromStartupCommand: "~/glint-attach.sh"))
        XCTAssertNil(BotRegistry.botName(fromStartupCommand: nil))
    }

    func testEndpointExpandsTildeAndSkipsBotsWithoutState() throws {
        let json = Data(#"{"ledger": {"state": "~/.claude/channels/telegram-ledger", "title": "财务"}, "tick": {"dir": "/tmp"}}"#.utf8)
        let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
        let bot = try XCTUnwrap(BotRegistry.endpoint(named: "ledger", botsJSON: json, home: home))
        XCTAssertEqual(bot.title, "财务")
        XCTAssertEqual(bot.apiEnvFile.path, "/Users/me/.claude/channels/telegram-ledger/api.env")
        XCTAssertNil(BotRegistry.endpoint(named: "tick", botsJSON: json, home: home))
        XCTAssertNil(BotRegistry.endpoint(named: "missing", botsJSON: json, home: home))
    }

    func testParseKeepsUnknownLinesAndReadsOwnedKeys() {
        let text = """
        # header
        GLINT_API_MODE=relay
        ANTHROPIC_BASE_URL=https://relay.example
        ANTHROPIC_AUTH_TOKEN=sk-a=b
        # model
        ANTHROPIC_MODEL=claude-sonnet-5-5

        """
        let config = BotAPIConfig(parsing: text)
        XCTAssertEqual(config.mode, .relay)
        XCTAssertEqual(config.baseURL, "https://relay.example")
        XCTAssertEqual(config.token, "sk-a=b", "only the first = splits key from value")
        XCTAssertEqual(config.otherLines, ["# header", "# model", "ANTHROPIC_MODEL=claude-sonnet-5-5"])
        XCTAssertTrue(config.usesRelay)
    }

    func testSwitchingToSubscriptionKeepsRelayValues() {
        var config = BotAPIConfig(parsing: "GLINT_API_MODE=relay\nANTHROPIC_BASE_URL=https://r\nANTHROPIC_AUTH_TOKEN=k\n")
        config.mode = .subscription
        let reparsed = BotAPIConfig(parsing: config.serialized())
        XCTAssertEqual(reparsed.mode, .subscription)
        XCTAssertEqual(reparsed.baseURL, "https://r")
        XCTAssertEqual(reparsed.token, "k")
        XCTAssertFalse(reparsed.usesRelay)
    }

    func testSerializedPutsOwnedKeysAfterLeadingComments() {
        let config = BotAPIConfig(parsing: "# a\n\n# b\nANTHROPIC_MODEL=m\nGLINT_API_MODE=relay\n")
        XCTAssertEqual(config.serialized(), """
        # a

        # b
        GLINT_API_MODE=relay
        ANTHROPIC_BASE_URL=
        ANTHROPIC_AUTH_TOKEN=
        ANTHROPIC_MODEL=m

        """)
    }

    func testUnknownModeAndHalfFilledRelayFallBackToSubscription() {
        XCTAssertEqual(BotAPIConfig(parsing: "GLINT_API_MODE=weird\n").mode, .subscription)
        XCTAssertFalse(BotAPIConfig(parsing: "GLINT_API_MODE=relay\nANTHROPIC_BASE_URL=https://r\n").usesRelay)
    }

    func testSaveWritesOwnerOnlyFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bot-api-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bot = BotEndpoint(name: "t", title: nil, stateDirectory: dir)
        try BotRegistry.save(BotAPIConfig(mode: .relay, baseURL: "https://r", token: "k"), for: bot)
        let attrs = try FileManager.default.attributesOfItem(atPath: bot.apiEnvFile.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(BotRegistry.load(bot)?.token, "k")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".api.env.") }
        XCTAssertEqual(leftovers, [])
    }

    func testRestartPatternMatchesOnlyThisBotsSettingsPath() {
        let bot = BotEndpoint(name: "ledger", title: nil,
                              stateDirectory: URL(fileURLWithPath: "/nonexistent/telegram-ledger", isDirectory: true))
        XCTAssertEqual(BotRegistry.claudeProcessPattern(for: bot),
                       #"^claude .*--settings /nonexistent/telegram-ledger/bin/session-settings\.json "#)
    }
}
