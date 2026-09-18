import XCTest
@testable import TriageCore

/// Excluding individual senders from an approved plan item.
///
/// Approval was all-or-nothing per item, so the smallest thing this app could execute was a whole
/// category — its first ever deletion would have been forty-four messages at once, on a path that had
/// never run, with an undo that had never run either. Excluding by message id makes a one-sender
/// rehearsal possible.
final class SelectiveApprovalTests: XCTestCase {

    private func entry(_ id: String, sender: String) -> ActionPlanEntry {
        ActionPlanEntry(
            messageId: id,
            sender: "Name <\(sender)>",
            senderEmail: sender,
            subject: "Subject \(id)",
            date: Date()
        )
    }

    private func item(excluding excluded: Set<String> = []) -> ActionPlanItem {
        ActionPlanItem(
            id: "promotion_deleted",
            category: .promotion,
            action: .deleted,
            entries: [
                entry("a1", sender: "keep@example.com"),
                entry("a2", sender: "keep@example.com"),
                entry("b1", sender: "drop@example.com"),
                entry("b2", sender: "drop@example.com"),
                entry("b3", sender: "drop@example.com"),
            ],
            isApproved: true,
            excludedMessageIds: excluded
        )
    }

    func testNoExclusionsBehavesExactlyAsBefore() {
        // The default must be indistinguishable from the old all-or-nothing item, or every existing
        // plan silently changes meaning.
        let i = item()
        XCTAssertEqual(i.approvedCount, 5)
        XCTAssertEqual(i.approvedEntries.map(\.messageId), ["a1", "a2", "b1", "b2", "b3"])
        XCTAssertFalse(i.isEffectivelyEmpty)
    }

    func testExcludedMessagesAreNotInTheApprovedSet() {
        let i = item(excluding: ["b1", "b2", "b3"])
        XCTAssertEqual(i.approvedCount, 2)
        XCTAssertEqual(i.approvedEntries.map(\.messageId), ["a1", "a2"])
    }

    func testExcludingEverythingLeavesNothingToDo() {
        // An approved item with all senders excluded must be visible as empty rather than executing
        // the full list, which is the failure this whole feature would be worst at.
        let i = item(excluding: ["a1", "a2", "b1", "b2", "b3"])
        XCTAssertEqual(i.approvedCount, 0)
        XCTAssertTrue(i.isEffectivelyEmpty)
    }

    func testPlanTotalsReflectExclusions() {
        // totalApproved GATES execution, so it must count what will actually happen.
        let plan = ActionPlan(
            accountId: 1,
            generatedAt: Date(),
            items: [item(excluding: ["b1", "b2", "b3"])],
            summary: ActionPlanSummary(totalEmails: 5, toArchive: 0, toDelete: 2)
        )
        XCTAssertEqual(plan.totalApproved, 2, "the gate must not count excluded mail")
    }

    func testAnUnapprovedItemContributesNothingHoweverItsExclusionsLook() {
        let unapproved = ActionPlanItem(
            id: "x", category: .promotion, action: .deleted,
            entries: [entry("a1", sender: "s@example.com")],
            isApproved: false
        )
        let plan = ActionPlan(
            accountId: 1, generatedAt: Date(), items: [unapproved],
            summary: ActionPlanSummary(totalEmails: 1, toArchive: 0, toDelete: 0)
        )
        XCTAssertEqual(plan.totalApproved, 0)
    }

    func testExclusionsSurviveBeingSetAfterConstruction() {
        // The view mutates this on a copy held in @State, so it has to be a var that actually takes.
        var i = item()
        i.excludedMessageIds.formUnion(["b1", "b2", "b3"])
        XCTAssertEqual(i.approvedCount, 2)
        i.excludedMessageIds.subtract(["b2"])
        XCTAssertEqual(i.approvedCount, 3)
    }

    func testAnUnknownExcludedIdIsHarmless() {
        // Stale ids can outlive a regenerated plan; they must not remove anything real.
        let i = item(excluding: ["does-not-exist"])
        XCTAssertEqual(i.approvedCount, 5)
    }
}
