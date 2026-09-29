import XCTest
@testable import Glint

final class GrokUsageReaderTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glint-grok-usage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - decode

    /// The shape the billing endpoint returns for a personal / credits
    /// account (on-demand cap > 0): percent, window label, and reset date
    /// all land in the quota's primary slot.
    func testDecodesCreditsAccountIntoPrimaryWindow() throws {
        let data = Data(#"""
        {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-09-02T07:39:39.262344+00:00","end":"2026-09-09T07:39:39.262344+00:00"},"onDemandCap":{"val":20},"onDemandUsed":{"val":5},"isUnifiedBillingUser":false,"prepaidBalance":{"val":0},"topUpMethod":"TOP_UP_METHOD_SAVED_PAYMENT_METHOD","billingPeriodStart":"2026-09-02T07:39:39.262344+00:00","billingPeriodEnd":"2026-09-09T07:39:39.262344+00:00"}}
        """#.utf8)

        let quota = try XCTUnwrap(GrokUsageReader.decode(data))

        XCTAssertEqual(quota.sessionPercent, 25, accuracy: 0.001)
        XCTAssertNil(quota.weeklyPercent)          // one window, not drawn twice
        XCTAssertEqual(quota.primaryWindowMinutes, 10_080)
        XCTAssertEqual(quota.primaryWindowLabel, "7d")
        XCTAssertEqual(quota.sessionResetsAt,
                       GrokUsageReaderTests.date("2026-09-09T07:39:39.262344+00:00"))
        XCTAssertNil(quota.weeklyResetsAt)
    }

    /// Amounts are proto-JSON `{"val": …}`; a string-typed val (observed in
    /// some payloads) must not crash the decode — it reads as nil.
    func testStringValuedAmountsDecodeWithoutCrashing() throws {
        let data = Data(#"""
        {"config":{"currentPeriod":{"start":"2026-09-02T07:39:39+00:00","end":"2026-09-09T07:39:39+00:00"},"onDemandCap":{"val":"20"},"onDemandUsed":{"val":"5"},"isUnifiedBillingUser":false}}
        """#.utf8)

        // cap decodes as nil → treated as 0 → no numbers on this surface.
        XCTAssertNil(GrokUsageReader.decode(data))
    }

    /// Team / unified-billing accounts report cap 0 — the surface doesn't
    /// expose usage numbers. The read still yields a quota so the row
    /// renders: period + reset countdown real, percent flagged unknown
    /// (rendered "—", never a fabricated 0%).
    func testTeamAccountWithZeroCapRendersUnknownPercent() throws {
        let data = Data(#"""
        {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-09-02T07:39:39.262344+00:00","end":"2026-09-09T07:39:39.262344+00:00"},"onDemandCap":{"val":0},"onDemandUsed":{"val":0},"isUnifiedBillingUser":true,"prepaidBalance":{"val":0},"topUpMethod":"TOP_UP_METHOD_SAVED_PAYMENT_METHOD","billingPeriodStart":"2026-09-02T07:39:39.262344+00:00","billingPeriodEnd":"2026-09-09T07:39:39.262344+00:00"}}
        """#.utf8)

        let quota = try XCTUnwrap(GrokUsageReader.decode(data))
        XCTAssertEqual(quota.percentUnknown, true)
        XCTAssertEqual(quota.sessionPercent, 0)
        XCTAssertEqual(quota.primaryWindowLabel, "7d")
        XCTAssertEqual(quota.sessionResetsAt,
                       GrokUsageReaderTests.date("2026-09-09T07:39:39.262344+00:00"))
        // Round-trips through the snapshot persistence path.
        let persisted = try JSONEncoder().encode(quota)
        let restored = try JSONDecoder().decode(AgentQuota.self, from: persisted)
        XCTAssertEqual(restored.percentUnknown, true)
    }

    /// Old snapshots persisted before `percentUnknown` existed decode as
    /// known — the field is absent from their JSON.
    func testLegacySnapshotWithoutPercentUnknownDecodesAsKnown() throws {
        let legacy = Data(#"""
        {"sessionPercent":42,"weeklyPercent":null,"sessionResetsAt":null,"weeklyResetsAt":null,"planType":null,"primaryWindowMinutes":10080,"secondaryWindowMinutes":null,"scopedWeekly":null}
        """#.utf8)
        let restored = try JSONDecoder().decode(AgentQuota.self, from: legacy)
        XCTAssertNotEqual(restored.percentUnknown, true)
    }

    /// A source-reported `creditUsagePercent` wins over cap math even when
    /// the cap reads 0 (prepaid surface).
    func testReportedCreditUsagePercentWins() throws {
        let data = Data(#"""
        {"config":{"currentPeriod":{"start":"2026-09-02T07:39:39+00:00","end":"2026-09-09T07:39:39+00:00"},"onDemandCap":{"val":0},"onDemandUsed":{"val":0},"creditUsagePercent":37.5,"isUnifiedBillingUser":false}}
        """#.utf8)

        let quota = try XCTUnwrap(GrokUsageReader.decode(data))
        XCTAssertNil(quota.percentUnknown)
        XCTAssertEqual(quota.sessionPercent, 37.5, accuracy: 0.001)
    }

    /// Over-cap readings clamp to 100 rather than blowing out the bar.
    func testUsedBeyondCapClampsTo100() throws {
        let data = Data(#"""
        {"config":{"currentPeriod":{"start":"2026-09-02T07:39:39+00:00","end":"2026-09-09T07:39:39+00:00"},"onDemandCap":{"val":10},"onDemandUsed":{"val":30},"isUnifiedBillingUser":false}}
        """#.utf8)

        let quota = try XCTUnwrap(GrokUsageReader.decode(data))
        XCTAssertEqual(quota.sessionPercent, 100, accuracy: 0.001)
    }

    /// A missing period still produces a quota with the observed weekly
    /// window as the label (never the AgentQuota default "5h").
    func testMissingPeriodFallsBackToWeeklyLabel() throws {
        let data = Data(#"""
        {"config":{"onDemandCap":{"val":100},"onDemandUsed":{"val":10},"isUnifiedBillingUser":false}}
        """#.utf8)

        let quota = try XCTUnwrap(GrokUsageReader.decode(data))
        XCTAssertNil(quota.sessionResetsAt)
        XCTAssertNil(quota.percentUnknown)
        XCTAssertEqual(quota.primaryWindowLabel, "7d")
    }

    func testMalformedPayloadYieldsNoQuota() {
        XCTAssertNil(GrokUsageReader.decode(Data("not json".utf8)))
        XCTAssertNil(GrokUsageReader.decode(Data("{}".utf8)))
        XCTAssertNil(GrokUsageReader.decode(Data(#"{"config":null}"#.utf8)))
    }

    // MARK: - token loading

    /// `~/.grok/auth.json` maps issuer URLs to credential objects; the first
    /// non-empty `key` (access token) wins across the map's entries.
    func testLoadsFirstNonEmptyTokenFromAuthMap() throws {
        let auth = home.appendingPathComponent("auth.json")
        try Data(#"""
        {"https://auth.x.ai::issuer":{"key":"","auth_mode":"oidc"},"https://auth.x.ai::other":{"key":"tok-123","auth_mode":"oidc"}}
        """#.utf8).write(to: auth)

        XCTAssertEqual(GrokUsageReader.loadToken(from: home), "tok-123")
    }

    /// An auth map whose entries carry no usable token behaves like no login.
    func testEmptyTokensYieldNoToken() throws {
        let auth = home.appendingPathComponent("auth.json")
        try Data(#"""
        {"https://auth.x.ai::issuer":{"key":"","auth_mode":"api_key"}}
        """#.utf8).write(to: auth)

        XCTAssertNil(GrokUsageReader.loadToken(from: home))
    }

    /// A malformed auth.json (not issuer-keyed JSON) yields nil, no crash.
    func testMalformedAuthYieldsNoToken() throws {
        let auth = home.appendingPathComponent("auth.json")
        try Data("[1,2,3]".utf8).write(to: auth)

        XCTAssertNil(GrokUsageReader.loadToken(from: home))
    }

    /// No auth.json (grok not installed / never logged in) → nil, no crash.
    func testMissingAuthYieldsNoQuota() async {
        let quota = await GrokUsageReader.read(grokHome: home)
        XCTAssertNil(quota)
    }

    // MARK: - helpers

    private static func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso)!
    }
}
