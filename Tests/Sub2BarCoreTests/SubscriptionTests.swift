import XCTest
@testable import Sub2BarCore

final class SubscriptionTests: XCTestCase {
    private func date(_ text: String) -> Date { parseAPIDate(text)! }

    func testCalendarMonthRatherThanThirtyDays() throws {
        let cycle = try XCTUnwrap(SubscriptionCycle(renewalDay: 12, at: date("2026-09-17T12:00:00Z"), timeZoneID: "UTC"))
        XCTAssertEqual(cycle.label, "2026-09-12 → 2026-10-11")
        let august = try XCTUnwrap(SubscriptionCycle(renewalDay: 12, at: date("2026-08-17T12:00:00Z"), timeZoneID: "UTC"))
        XCTAssertEqual(august.end.timeIntervalSince(august.start), 31 * 86400)
    }

    func testBoundaryBelongsToNewCycleAndRollsAcrossYear() throws {
        let before = try XCTUnwrap(SubscriptionCycle(renewalDay: 12, at: date("2026-01-11T23:59:59Z"), timeZoneID: "UTC"))
        XCTAssertEqual(before.label, "2025-12-12 → 2026-01-11")
        let after = try XCTUnwrap(SubscriptionCycle(renewalDay: 12, at: date("2026-01-12T00:00:00Z"), timeZoneID: "UTC"))
        XCTAssertEqual(after.start, before.end)
        XCTAssertEqual(after.label, "2026-01-12 → 2026-02-11")
    }

    func testShortMonthClampsWithoutDriftingOriginalDay() throws {
        for (text, expected) in [
            ("2026-02-15T12:00:00Z", "2026-01-31 → 2026-02-27"),
            ("2026-03-15T12:00:00Z", "2026-02-28 → 2026-03-30"),
            ("2024-03-15T12:00:00Z", "2024-02-29 → 2024-03-30"),
            ("2026-05-15T12:00:00Z", "2026-04-30 → 2026-05-30")
        ] {
            XCTAssertEqual(SubscriptionCycle(renewalDay: 31, at: date(text), timeZoneID: "UTC")?.label, expected)
        }
    }

    func testExplicitTimezoneAndDSTUseLocalMidnight() throws {
        let instant = date("2026-09-11T16:00:00Z")
        XCTAssertEqual(SubscriptionCycle(renewalDay: 12, at: instant, timeZoneID: "Asia/Shanghai")?.label, "2026-09-12 → 2026-10-11")
        XCTAssertEqual(SubscriptionCycle(renewalDay: 12, at: instant, timeZoneID: "UTC")?.label, "2026-08-12 → 2026-09-11")
        let dst = try XCTUnwrap(SubscriptionCycle(renewalDay: 1, at: date("2026-03-15T12:00:00Z"), timeZoneID: "America/New_York"))
        XCTAssertEqual(dst.start, date("2026-03-01T05:00:00Z"))
        XCTAssertEqual(dst.end, date("2026-04-01T04:00:00Z"))
        XCTAssertEqual(dst.label, "2026-03-01 → 2026-03-31")
        XCTAssertNil(SubscriptionCycle(renewalDay: 0, at: instant, timeZoneID: "UTC"))
        XCTAssertNil(SubscriptionCycle(renewalDay: 32, at: instant, timeZoneID: "UTC"))
        XCTAssertNil(SubscriptionCycle(renewalDay: 12, at: instant, timeZoneID: "not-a-timezone"))
    }

    func testFifteenthRenewalDisplaysInclusiveFourteenthAndChangesAtMidnight() throws {
        let before = try XCTUnwrap(SubscriptionCycle(renewalDay: 15, at: date("2026-10-14T15:59:59Z"), timeZoneID: "Asia/Shanghai"))
        XCTAssertEqual(before.label, "2026-09-15 → 2026-10-14")
        XCTAssertEqual(before.shortLabel, "09/15–10/14")
        XCTAssertEqual(before.lastIncludedDate, date("2026-10-14T15:59:59Z"))
        let after = try XCTUnwrap(SubscriptionCycle(renewalDay: 15, at: date("2026-10-14T16:00:00Z"), timeZoneID: "Asia/Shanghai"))
        XCTAssertEqual(after.label, "2026-10-15 → 2026-11-14")
        XCTAssertEqual(after.start, before.end)
        XCTAssertLessThan(before.lastIncludedDate, after.start)
    }

    func testMissingConfigurationExcludedButExplicitZeroIsValid() throws {
        XCTAssertFalse(AccountSubscription().isComplete)
        XCTAssertFalse(AccountSubscription(monthlyPrice: 20).isComplete)
        XCTAssertFalse(AccountSubscription(renewalDay: 12).isComplete)
        XCTAssertFalse(AccountSubscription(monthlyPrice: -1, renewalDay: 12).isComplete)
        XCTAssertFalse(AccountSubscription(monthlyPrice: .nan, renewalDay: 12).isComplete)
        XCTAssertTrue(AccountSubscription(monthlyPrice: 0, renewalDay: 31).isComplete)
        XCTAssertEqual(try AccountSubscription.parseMonthlyPrice(" 19.99 "), Decimal(string: "19.99"))
        XCTAssertEqual(try AccountSubscription.parseMonthlyPrice("0"), 0)
        XCTAssertNil(try AccountSubscription.parseMonthlyPrice(" "))
        for value in ["-1", "NaN", "1.234", "1,23", "1abc", "1000000000", "1e2"] {
            XCTAssertThrowsError(try AccountSubscription.parseMonthlyPrice(value))
        }
    }

    func testLocalMetadataRoundTripsAndSeparatesServers() throws {
        var preferences = SubscriptionPreferences()
        preferences.set(AccountSubscription(monthlyPrice: 200, renewalDay: 12), id: 7, server: "https://a.invalid")
        preferences.set(AccountSubscription(monthlyPrice: 20, renewalDay: 1), id: 7, server: "https://b.invalid")
        let restored = try JSONDecoder().decode(SubscriptionPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(restored.subscriptions(for: "https://a.invalid")[7]?.monthlyPrice, 200)
        XCTAssertEqual(restored.subscriptions(for: "https://b.invalid")[7]?.monthlyPrice, 20)
        preferences.set(nil, id: 7, server: "https://a.invalid")
        XCTAssertTrue(preferences.subscriptions(for: "https://a.invalid").isEmpty)
        XCTAssertEqual(preferences.subscriptions(for: "https://b.invalid").count, 1)
    }

    func testConfigurationMigrationAndStatisticsSettingsRoundTrip() throws {
        let old = try JSONDecoder().decode(Configuration.self, from: Data(#"{"serverURL":"https://example.invalid","refreshInterval":15}"#.utf8))
        XCTAssertTrue(old.includeAdminUsage)
        XCTAssertNotNil(TimeZone(identifier: old.subscriptionTimeZoneID))
        XCTAssertEqual(old.actualCostCurrency, "$")
        XCTAssertEqual(old.subscriptionCostCurrency, "$")
        var new = old; new.includeAdminUsage = false; new.subscriptionTimeZoneID = "UTC"
        new.actualCostCurrency = "¥"; new.subscriptionCostCurrency = "HK$"
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(new)), new)
    }

    func testCurrencyLabelsNeverConvertAmountOrChangeDecimalPrecision() throws {
        let amount = Decimal(string: "1234.56")!
        XCTAssertEqual(CurrencyUnit.format(amount), "$1,234.56")
        for unit in ["$", "¥", "HK$", "€", "元", "USDT", "cny"] {
            XCTAssertTrue(CurrencyUnit.format(amount, unit: unit).contains("1,234.56"), unit)
        }
        XCTAssertEqual(CurrencyUnit.format(amount, unit: "¥"), "¥1,234.56")
        XCTAssertEqual(CurrencyUnit.format(amount, unit: "元"), "元1,234.56")
        XCTAssertEqual(CurrencyUnit.format(amount, unit: "USDT"), "USDT1,234.56")
        XCTAssertEqual(CurrencyUnit.format(amount, unit: "cny"), "cny1,234.56")
        XCTAssertEqual(CurrencyUnit.format(0, unit: "JPY").suffix(4), "0.00")
        XCTAssertEqual(CurrencyUnit.format(nil, unit: "CNY"), "—")
        XCTAssertEqual(CurrencyUnit.format(.nan, unit: "CNY"), "—")
    }

    func testCurrencyLabelValidationAndNormalization() throws {
        XCTAssertEqual(try CurrencyUnit.normalized(" cny "), "cny")
        XCTAssertEqual(try CurrencyUnit.normalized("元"), "元")
        for unit in ["", " ", "USD\nCNY", "USD\u{202E}CNY", String(repeating: "A", count: 13)] {
            XCTAssertThrowsError(try CurrencyUnit.normalized(unit))
        }
    }

    func testLegacyCodesMigrateOnceButNewSymbolsRemainLiteral() throws {
        let legacy = try JSONDecoder().decode(Configuration.self, from: Data(#"{"actualCostCurrency":"CNY","subscriptionCostCurrency":"USD"}"#.utf8))
        XCTAssertEqual(legacy.actualCostCurrency, "¥")
        XCTAssertEqual(legacy.subscriptionCostCurrency, "$")
        XCTAssertEqual(CurrencyUnit.format(230.87, unit: legacy.actualCostCurrency), "¥230.87")
        var custom = legacy
        custom.actualCostCurrency = "cny"
        custom.subscriptionCostCurrency = "US$"
        let restored = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(custom))
        XCTAssertEqual(restored.actualCostCurrency, "cny")
        XCTAssertEqual(restored.subscriptionCostCurrency, "US$")
    }
}
