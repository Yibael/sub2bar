import XCTest
@testable import Sub2BarCore

final class ResetCountdownTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDaysAndHours() {
        XCTAssertEqual(text(after: 3 * 86_400 + 2 * 3_600 + 59 * 60), "3d 2h")
        XCTAssertEqual(text(after: 86_400), "1d 0h")
    }

    func testHoursAndMinutes() {
        XCTAssertEqual(text(after: 23 * 3_600 + 59 * 60), "23h 59m")
        XCTAssertEqual(text(after: 2 * 3_600 + 15 * 60), "2h 15m")
        XCTAssertEqual(text(after: 3_600), "1h 0m")
    }

    func testMinutesAndLessThanOneMinute() {
        XCTAssertEqual(text(after: 59 * 60), "59m")
        XCTAssertEqual(text(after: 60), "1m")
        XCTAssertEqual(text(after: 59), "<1m")
        XCTAssertEqual(text(after: 0.5), "<1m")
    }

    func testExpiredDeadlineWaitsForNewData() {
        XCTAssertEqual(text(after: 0), "等待更新")
        XCTAssertEqual(text(after: -3_600), "等待更新")
    }

    func testMissingOrInvalidDeadlineIsUnknown() {
        XCTAssertEqual(ResetCountdown.text(until: nil, at: now), "—")
        XCTAssertEqual(ResetCountdown.text(until: Date(timeIntervalSince1970: .nan), at: now), "—")
        XCTAssertEqual(ResetCountdown.text(until: Date(timeIntervalSince1970: .infinity), at: now), "—")
        XCTAssertEqual(ResetCountdown.text(until: Date(timeIntervalSince1970: .greatestFiniteMagnitude), at: now), "—")
    }

    func testSameDeadlineCountsDownWithoutNewSnapshot() {
        let deadline = now.addingTimeInterval(3 * 86_400 + 2 * 3_600)
        XCTAssertEqual(ResetCountdown.text(until: deadline, at: now), "3d 2h")
        XCTAssertEqual(ResetCountdown.text(until: deadline, at: now.addingTimeInterval(3_600)), "3d 1h")
        XCTAssertEqual(ResetCountdown.text(until: deadline, at: deadline), "等待更新")
    }

    private func text(after seconds: TimeInterval) -> String {
        ResetCountdown.text(until: now.addingTimeInterval(seconds), at: now)
    }
}
