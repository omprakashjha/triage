import XCTest
@testable import TriageCore

/// The review-queue query, isolated from the view.
///
/// Written because the Review screen showed nothing twice while the database held 103 matching
/// rows, and the first two explanations were guesses. This separates the two candidates: if the
/// query and decode work here, the fault is in the view's lifecycle, and if they do not, it is
/// here. Guessing a third time was not an option.
final class ReviewQueueQueryTests: XCTestCase {
    private var db: AppDatabase!
    private var accountId: Int64!

    override func setUp() async throws {
        db = try AppDatabase.inMemory()
        var account = EmailAccount(email: "me@example.com", provider: .gmail, createdAt: Date())
        try await db.saveAccount(&account)
        accountId = account.id!
    }

    private func seed(
        tier: SafetyTier,
        sender: String = "info@email.ns.nl",
        subject: String = "Maak kans op een jaar gratis treinen",
        decision: DisposalDecision? = nil
    ) async throws {
        var email = EmailMetadata(
            accountId: accountId,
            messageId: UUID().uuidString,
            threadId: "t",
            sender: "NS <\(sender)>",
            senderEmail: sender,
            subject: subject,
            date: Date(),
            hasListUnsubscribe: true
        )
        email.category = .promotion
        email.safetyTier = tier
        email.categoryReason = "AI read this message: prize draw"
        email.labels = ["INBOX", "CATEGORY_UPDATES"]
        email.userDisposalDecision = decision
        try await db.upsertEmails([email])
    }

    func testReviewMailIsReturned() async throws {
        try await seed(tier: .review)
        try await seed(tier: .review, subject: "Profiteer van weg = weg acties")

        let queue = try await db.emailsAwaitingReview(accountId: accountId)

        XCTAssertEqual(queue.count, 2, "mail in the review tier must come back")
    }

    func testOtherTiersAreExcluded() async throws {
        try await seed(tier: .review)
        try await seed(tier: .safe)
        try await seed(tier: .protected_)

        let queue = try await db.emailsAwaitingReview(accountId: accountId)

        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.first?.safetyTier, .review)
    }

    func testRowsDecodeIncludingTheNewDecisionColumn() async throws {
        // The decode is the other half of the query. A record that fails to decode surfaces as
        // an empty list plus a swallowed error, which looks exactly like "no matching mail".
        try await seed(tier: .review, decision: nil)
        try await seed(tier: .review, subject: "Second", decision: .keep)

        let queue = try await db.emailsAwaitingReview(accountId: accountId)

        XCTAssertEqual(queue.count, 2)
        XCTAssertTrue(queue.contains { $0.userDisposalDecision == .keep })
        XCTAssertTrue(queue.contains { $0.userDisposalDecision == nil })
        // Everything the screen renders per row must survive the round trip.
        XCTAssertTrue(queue.allSatisfy { !$0.subject.isEmpty })
        XCTAssertTrue(queue.allSatisfy { $0.categoryReason != nil })
    }

    func testAnotherAccountsMailIsNotReturned() async throws {
        var other = EmailAccount(email: "other@example.com", provider: .gmail, createdAt: Date())
        try await db.saveAccount(&other)
        try await seed(tier: .review)

        let queue = try await db.emailsAwaitingReview(accountId: other.id!)
        XCTAssertTrue(queue.isEmpty)
    }

    func testDecisionsPersistAndAreCounted() async throws {
        try await seed(tier: .review)
        let queue = try await db.emailsAwaitingReview(accountId: accountId)
        let ids = queue.map(\.messageId)

        try await db.recordDisposalDecision(.dispose, messageIds: ids, accountId: accountId)

        let counts = try await db.disposalDecisionCounts(accountId: accountId)
        XCTAssertEqual(counts.dispose, ids.count)
        XCTAssertEqual(counts.keep, 0)
    }
}
