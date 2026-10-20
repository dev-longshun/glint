import XCTest
@testable import Glint

/// Fork: Telegram remote confirm — staleness, routing, truncation, redaction.
final class ConfirmationRelayTests: XCTestCase {
    private let pane = "12345678-1234-1234-1234-123456789ABC:7"
    private let otherPane = "12345678-1234-1234-1234-123456789ABC:8"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: ledger

    func testPushStaysLiveUntilThePaneMovesOn() {
        var ledger = ConfirmationLedger()
        _ = ledger.noteEvent(hook: "Stop", pane: pane)
        ledger.register(token: "tok", pane: pane, text: "hi", at: t0)
        XCTAssertTrue(ledger.attach(messageID: 100, to: "tok"))
        XCTAssertEqual(ledger.live(token: "tok", now: t0)?.messageIDs, [100])

        // Claude's own idle reminder is not a new turn.
        XCTAssertEqual(ledger.noteEvent(hook: "Notification", pane: pane), [])
        XCTAssertNotNil(ledger.live(token: "tok", now: t0))

        // Another pane's activity doesn't touch this push.
        XCTAssertEqual(ledger.noteEvent(hook: "UserPromptSubmit", pane: otherPane), [])
        XCTAssertNotNil(ledger.live(token: "tok", now: t0))

        // Answering on the computer starts a new turn: the phone's buttons die.
        let stale = ledger.noteEvent(hook: "UserPromptSubmit", pane: pane)
        XCTAssertEqual(stale.map(\.token), ["tok"])
        XCTAssertEqual(stale.first?.messageIDs, [100])
        XCTAssertNil(ledger.live(token: "tok", now: t0))
        XCTAssertNil(ledger.live(messageID: 100, now: t0))
    }

    func testMessageInFlightWhenThePaneMovesOnIsReportedStale() {
        var ledger = ConfirmationLedger()
        ledger.register(token: "tok", pane: pane, text: "hi", at: t0)
        // No message id yet, so nothing to edit — but the push is gone.
        XCTAssertEqual(ledger.noteEvent(hook: "PreToolUse", pane: pane).map(\.messageIDs), [[]])
        XCTAssertFalse(ledger.attach(messageID: 100, to: "tok"))
    }

    func testReplyToForceReplyPromptRoutesToThePush() {
        var ledger = ConfirmationLedger()
        ledger.register(token: "tok", pane: pane, text: "hi", at: t0)
        ledger.attach(messageID: 100, to: "tok")
        ledger.attach(messageID: 101, to: "tok")
        XCTAssertEqual(ledger.live(messageID: 101, now: t0)?.pane, pane)
        XCTAssertEqual(ledger.live(messageID: 100, now: t0)?.token, "tok")
        XCTAssertNil(ledger.live(messageID: 999, now: t0))
    }

    func testOldPushExpiresAndStopsBlockingHibernation() {
        var ledger = ConfirmationLedger()
        ledger.register(token: "tok", pane: pane, text: "hi", at: t0)
        XCTAssertTrue(ledger.hasLivePush(pane: pane, now: t0.addingTimeInterval(60)))
        XCTAssertFalse(ledger.hasLivePush(pane: otherPane, now: t0))
        let late = t0.addingTimeInterval(ConfirmationLedger.maxAge + 1)
        XCTAssertNil(ledger.live(token: "tok", now: late))
        XCTAssertFalse(ledger.hasLivePush(pane: pane, now: late))
    }

    func testRemovedPushCannotBeAnsweredTwice() {
        var ledger = ConfirmationLedger()
        ledger.register(token: "tok", pane: pane, text: "hi", at: t0)
        XCTAssertNotNil(ledger.remove("tok"))
        XCTAssertNil(ledger.live(token: "tok", now: t0))
        XCTAssertNil(ledger.remove("tok"))
    }

    func testCapacityEvictsOldestPushes() {
        var ledger = ConfirmationLedger()
        for i in 0..<ConfirmationLedger.capacity {
            XCTAssertEqual(ledger.register(token: "t\(i)", pane: "p\(i)", text: "", at: t0.addingTimeInterval(Double(i))), [])
        }
        let evicted = ledger.register(token: "new", pane: pane, text: "", at: t0.addingTimeInterval(1_000))
        XCTAssertEqual(evicted.map(\.token), ["t0"])
        XCTAssertEqual(ledger.pushes.count, ConfirmationLedger.capacity)
        XCTAssertNotNil(ledger.live(token: "new", now: t0.addingTimeInterval(1_000)))
    }

    // MARK: callback data

    func testCallbackDataRoundTripsAndFitsTelegramLimit() {
        let token = ConfirmationRelay.makeToken()
        let data = ConfirmationRelay.callbackData(.approve, token)
        XCTAssertLessThanOrEqual(data.utf8.count, 64)
        XCTAssertEqual(ConfirmationRelay.parseCallback(data)?.action, .approve)
        XCTAssertEqual(ConfirmationRelay.parseCallback(data)?.token, token)
        XCTAssertEqual(ConfirmationRelay.parseCallback("r:abc")?.action, .reply)
        XCTAssertNil(ConfirmationRelay.parseCallback("x:abc"))
        XCTAssertNil(ConfirmationRelay.parseCallback("a:"))
        XCTAssertNil(ConfirmationRelay.parseCallback("garbage"))
    }

    // MARK: text

    func testShortMessageIsSentWhole() {
        let text = ConfirmationRelay.compose(header: "glint · main", body: "回「执行」我就开始。",
                                             elidedMarker: "…")
        XCTAssertEqual(text, "glint · main\n\n回「执行」我就开始。")
    }

    func testLongMessageKeepsItsEndWithinTelegramLimit() {
        let body = String(repeating: "前文😀", count: 3_000) + "\n要不要执行？"
        let text = ConfirmationRelay.compose(header: "glint · main", body: body, elidedMarker: "…（前文已省略）")
        XCTAssertTrue(text.hasPrefix("glint · main\n\n…（前文已省略）\n"))
        XCTAssertTrue(text.hasSuffix("\n要不要执行？"))
        XCTAssertLessThanOrEqual(text.utf16.count,
                                 ConfirmationRelay.telegramLimit - ConfirmationRelay.statusReserve)
        // Room left for the status line an edit adds later.
        let edited = ConfirmationRelay.appendingStatus("✅ 已执行 · 14:03", to: text)
        XCTAssertTrue(edited.hasSuffix("\n\n✅ 已执行 · 14:03"))
        XCTAssertLessThanOrEqual(edited.utf16.count, ConfirmationRelay.telegramLimit)
    }

    func testStatusReplacesTextThatWouldOverflow() {
        let full = String(repeating: "a", count: ConfirmationRelay.telegramLimit)
        XCTAssertEqual(ConfirmationRelay.appendingStatus("⌛", to: full), "⌛")
    }

    // MARK: redaction

    func testRedactsKeysAndCredentials() {
        let r = { ConfirmationRelay.redact($0, label: "x") }
        XCTAssertEqual(r("key: sk-ant-api03-abcdefghijklmnop"), "key: [x:anthropic_key]")
        XCTAssertEqual(r("密钥是sk-proj-ABCDEFGHIJKLMNOP1234"), "密钥是[x:api_key]")
        XCTAssertEqual(r("Authorization: Bearer abcdefghijklmnopqrstuvwxyz"),
                       "Authorization: Bearer [x:bearer]")
        XCTAssertEqual(r("password=hunter2hunter2"), "password=[x:secret_assign]")
        XCTAssertEqual(r("密码：Zx9!pass，记得改"), "密码：[x:secret_assign]，记得改")
        XCTAssertEqual(r("ghp_abcdefghijklmnopqrstuvwxyz123"), "[x:github_token]")
        XCTAssertEqual(r("AKIAABCDEFGHIJKLMNOP"), "[x:aws_key]")
        XCTAssertEqual(r("me@example.com"), "[x:email]")
        XCTAssertEqual(r("phone 13812345678."), "phone [x:phone].")
        XCTAssertEqual(r("ssh root@10.0.0.12"), "ssh root@[x:ipv4]")
        XCTAssertEqual(r("user@mail.com----Pa55word----backup"), "[x:account_dump]")
        XCTAssertEqual(r("https://x.dev/cb?sig=abcdef123456&a=1"),
                       "https://x.dev/cb?sig=[x:url_secret]&a=1")
        XCTAssertEqual(r("token AbCdEf0123456789XyZ"), "token [x:long_secret]")
        XCTAssertEqual(r("-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY-----"),
                       "[x:private_key]")
    }

    func testLeavesOrdinaryTextAlone() {
        let plain = """
        改 Glint/Agent/AgentHookInstaller.swift:365，跑 AgentHookRoutingTests。
        | 文件 | 说明 |
        |------|------|
        commit 7f064f3，uuid 123e4567-e89b-12d3-a456-426614174000，toolu_01AbCdEf23GhIjKl45
        """
        XCTAssertEqual(ConfirmationRelay.redact(plain), plain)
    }
}
