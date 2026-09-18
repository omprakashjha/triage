import XCTest
@testable import TriageCore

/// Splitting a plan item by safety tier.
///
/// Approval used to be all-or-nothing across a whole category: one review-tier message withheld
/// every safe message beside it. Measured on a real mailbox that held 122 of 181 safe emails —
/// 54 safe promotions blocked by 16 review siblings, 61 safe newsletters by 2, 7 safe transactional
/// by 1 — and it was why `notification`, the one category with no review mail, was the only category
/// the app ever acted on. Splitting doubled the share of disposable mail actually swept (30.5% to
/// 62.4%) with destructive precision unchanged at 100%.
final class ActionPlanTierSplitTests: XCTestCase {

    private func email(
        _ id: String,
        category: EmailCategory,
        tier: SafetyTier,
        daysOld: Double = 120
    ) -> EmailMetadata {
        var e = EmailMetadata(
            accountId: 1,
            messageId: id,
            threadId: "t-\(id)",
            sender: "Sender <s@example.com>",
            senderEmail: "s@example.com",
            subject: "Subject \(id)",
            date: Date().addingTimeInterval(-daysOld * 86_400)
        )
        e.category = category
        e.safetyTier = tier
        return e
    }

    private func plan(_ emails: [EmailMetadata]) -> ActionPlan {
        ActionPlanner(rules: .default).generatePlan(emails: emails, accountId: 1)
    }

    func testSafeMailIsApprovedDespiteAReviewSibling() {
        // The defect this exists for: one undecided message must not veto mail cleared on its own
        // evidence.
        let emails = [
            email("s1", category: .promotion, tier: .safe),
            email("s2", category: .promotion, tier: .safe),
            email("s3", category: .promotion, tier: .safe),
            email("r1", category: .promotion, tier: .review),
        ]
        let result = plan(emails)

        let approvedIds = Set(
            result.items.filter(\.isApproved).flatMap { $0.entries.map(\.messageId) }
        )
        XCTAssertEqual(approvedIds, ["s1", "s2", "s3"],
                       "the three cleared messages must be approved even though a fourth is not")
    }

    func testReviewMailIsNeverAutoApproved() {
        // The safety invariant. Splitting must not become a route to approving undecided mail.
        let emails = [
            email("s1", category: .promotion, tier: .safe),
            email("r1", category: .promotion, tier: .review),
            email("r2", category: .promotion, tier: .review),
        ]
        let result = plan(emails)

        for item in result.items where item.isApproved {
            for entry in item.entries {
                XCTAssertFalse(entry.messageId.hasPrefix("r"),
                               "review-tier mail appeared in an approved item")
            }
        }
    }

    func testUndecidedMailIsStillPresentedRatherThanDropped() {
        // Silently omitting mail the engine could not judge would hide the work outstanding.
        let emails = [
            email("s1", category: .promotion, tier: .safe),
            email("r1", category: .promotion, tier: .review),
        ]
        let result = plan(emails)

        let allIds = Set(result.items.flatMap { $0.entries.map(\.messageId) })
        XCTAssertTrue(allIds.contains("r1"), "the undecided message must still be visible")
        let heldItem = result.items.first { $0.entries.contains { $0.messageId == "r1" } }
        XCTAssertEqual(heldItem?.isApproved, false)
    }

    func testProtectedMailNeverEntersThePlanAtAll() {
        // Unchanged by the split, and worth pinning beside it.
        let emails = [
            email("s1", category: .promotion, tier: .safe),
            email("p1", category: .promotion, tier: .protected_),
        ]
        let result = plan(emails)
        let allIds = Set(result.items.flatMap { $0.entries.map(\.messageId) })
        XCTAssertFalse(allIds.contains("p1"))
    }

    func testACategoryOfOnlySafeMailBehavesAsBefore() {
        // No regression for the case that already worked — this is how `notification` behaved, and
        // it must keep behaving that way.
        let emails = [
            email("s1", category: .notification, tier: .safe),
            email("s2", category: .notification, tier: .safe),
        ]
        let result = plan(emails)
        let approved = result.items.filter(\.isApproved)
        XCTAssertEqual(approved.flatMap { $0.entries.map(\.messageId) }.sorted(), ["s1", "s2"])
    }

    func testUnknownCategoryIsStillNeverApproved() {
        let emails = [
            email("s1", category: .unknown, tier: .safe),
        ]
        let result = plan(emails)
        for item in result.items where item.isApproved {
            XCTAssertNotEqual(item.category, .unknown)
        }
    }
}
