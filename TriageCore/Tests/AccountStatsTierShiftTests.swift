import XCTest
@testable import TriageCore

/// The arithmetic behind counts that update before their write lands.
final class AccountStatsTierShiftTests: XCTestCase {

    private func stats(_ tiers: [SafetyTier: Int]) -> AccountStats {
        AccountStats(
            totalEmails: tiers.values.reduce(0, +),
            unreadEmails: 0,
            uncategorizedEmails: 0,
            categoryBreakdown: [:],
            tierBreakdown: tiers
        )
    }

    func testMovingEmailsBetweenTiers() {
        let shifted = stats([.review: 75, .safe: 92, .protected_: 224])
            .movingTier(from: .review, to: .safe, count: 3)
        XCTAssertEqual(shifted.needsReview, 72)
        XCTAssertEqual(shifted.safeToAction, 95)
        XCTAssertEqual(shifted.protected_, 224, "untouched tiers stay put")
    }

    func testTheTotalIsUnchanged() {
        // A decision reclassifies mail, it does not add or remove any.
        let before = stats([.review: 10, .safe: 5])
        let after = before.movingTier(from: .review, to: .protected_, count: 4)
        XCTAssertEqual(after.totalEmails, before.totalEmails)
    }

    func testItCannotGoNegative() {
        // Only visible rows are counted, so an overcount is possible. It must degrade to zero
        // rather than render a negative tier count at the user.
        let shifted = stats([.review: 2, .safe: 0]).movingTier(from: .review, to: .safe, count: 9)
        XCTAssertEqual(shifted.needsReview, 0)
        XCTAssertEqual(shifted.safeToAction, 9)
    }

    func testNoOpCases() {
        let original = stats([.review: 7])
        XCTAssertEqual(original.movingTier(from: .review, to: .safe, count: 0).needsReview, 7)
        XCTAssertEqual(original.movingTier(from: .review, to: .review, count: 3).needsReview, 7,
                       "a decision that does not change the tier changes no count")
    }

    func testAnAbsentDestinationTierIsCreated() {
        let shifted = stats([.review: 4]).movingTier(from: .review, to: .protected_, count: 4)
        XCTAssertEqual(shifted.needsReview, 0)
        XCTAssertEqual(shifted.protected_, 4)
    }
}
