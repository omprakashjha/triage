import XCTest
@testable import TriageCore

/// The exact sequence a drag performs, end to end against a real database.
///
/// Written because the row was reported as not leaving the list after a decision. That symptom has
/// two possible homes — the data did not change, or the view did not re-read it — and they need
/// completely different fixes. This pins the data half so the remaining question is unambiguous.
final class DecideThenReloadTests: XCTestCase {
    private var db: AppDatabase!
    private var accountId: Int64!

    override func setUp() async throws {
        db = try AppDatabase.inMemory()
        var account = EmailAccount(email: "me@example.com", provider: .gmail, createdAt: Date())
        try await db.saveAccount(&account)
        accountId = account.id!
    }

    private func reviewEmail(_ id: String, sender: String, subject: String) -> EmailMetadata {
        var email = EmailMetadata(
            accountId: accountId,
            messageId: id,
            threadId: "t-\(id)",
            sender: "Name <\(sender)>",
            senderEmail: sender,
            subject: subject,
            date: Date()
        )
        email.category = .notification
        email.safetyTier = .review
        email.categoryConfidence = 0.5
        email.categoryReason = "model read it: disposable, uncorroborated"
        return email
    }

    /// Replays what AppState does: save the correction, rebuild the engine WITH it, recategorize
    /// the sender, persist, then re-run the review query the list uses.
    private func decide(
        email: EmailMetadata,
        mustKeep: Bool,
        pattern: String
    ) async throws -> [EmailMetadata] {
        let correction = UserCorrection(
            accountId: accountId,
            senderEmail: email.senderEmail,
            subjectPattern: pattern,
            category: email.category ?? .unknown,
            mustKeep: mustKeep,
            previousCategory: email.category,
            previousTier: email.safetyTier,
            previousReason: email.categoryReason
        )
        try await db.saveCorrection(correction)

        let corrections = try await db.corrections(accountId: accountId)
        XCTAssertFalse(corrections.isEmpty, "the correction must be readable back, or the engine cannot see it")

        let senderEmails = try await db.emails(accountId: accountId, senderEmail: email.senderEmail)
        let engine = CorrectingEngine(base: RuleBasedEngine(), corrections: corrections)
        let results = try await engine.categorize(emails: senderEmails)
        try await db.updateCategories(results, accountId: accountId)

        return try await db.fetchEmailsForReview(accountId: accountId)
    }

    func testADecidedEmailLeavesTheReviewQuery() async throws {
        let email = reviewEmail("a", sender: "donotreply@interactivebrokers.com",
                                subject: "Daily Activity Statement for 08/27/2026")
        try await db.upsertEmails([email])
        let before = try await db.fetchEmailsForReview(accountId: accountId).count
        XCTAssertEqual(before, 1)

        let remaining = try await decide(
            email: email, mustKeep: false, pattern: "daily activity statement"
        )
        XCTAssertTrue(
            remaining.isEmpty,
            "the review list must no longer return it — it is still there, so the data path is at fault"
        )
    }

    func testKeepingAlsoRemovesItFromReview() async throws {
        let email = reviewEmail("a", sender: "x@example.com", subject: "Trade Confirmation")
        try await db.upsertEmails([email])

        let remaining = try await decide(
            email: email, mustKeep: true, pattern: "trade confirmation"
        )
        XCTAssertTrue(remaining.isEmpty)
    }

    func testTheStemRemovesEveryRecurringIssueAtOnce() async throws {
        // The whole point of the stem: one decision empties the family.
        let subjects = [
            "Daily Activity Statement for 08/27/2026",
            "Daily Activity Statement for 09/01/2026",
            "Daily Activity Statement for 09/13/2026",
        ]
        var emails: [EmailMetadata] = []
        for (i, subject) in subjects.enumerated() {
            emails.append(reviewEmail("m\(i)", sender: "ib@example.com", subject: subject))
        }
        // Different mail from the same sender, which must NOT be swept up.
        emails.append(reviewEmail("other", sender: "ib@example.com", subject: "Earnings Notification"))
        try await db.upsertEmails(emails)
        let before = try await db.fetchEmailsForReview(accountId: accountId).count
        XCTAssertEqual(before, 4)

        let (pattern, didGeneralize) = SubjectStem.decisionPattern(
            for: "Daily Activity Statement for 08/27/2026"
        )
        XCTAssertTrue(didGeneralize)

        let remaining = try await decide(emails: emails[0], mustKeep: false, pattern: pattern)
        XCTAssertEqual(remaining.count, 1, "all three statements go, the earnings notice stays")
        XCTAssertEqual(remaining.first?.subject, "Earnings Notification")
    }

    // Overload so the test above reads naturally.
    private func decide(
        emails email: EmailMetadata,
        mustKeep: Bool,
        pattern: String
    ) async throws -> [EmailMetadata] {
        try await decide(email: email, mustKeep: mustKeep, pattern: pattern)
    }

    func testSeveralDecisionsOnOneSenderAllSurvive() async throws {
        // Working quickly through one sender's mail means several corrections for that sender, and
        // each decision recategorizes ALL of its mail. If a later pass did not see the earlier
        // corrections it would revert them, which is the data-level half of the bug where only the
        // first drag appeared to take effect. This pins that they accumulate.
        let emails = [
            reviewEmail("a", sender: "ib@example.com", subject: "Daily Activity Statement for 08/27/2026"),
            reviewEmail("b", sender: "ib@example.com", subject: "Earnings Notification"),
            reviewEmail("c", sender: "ib@example.com", subject: "Trade Confirmation 12345"),
        ]
        try await db.upsertEmails(emails)

        // Three decisions in sequence, mixing keep and discard.
        _ = try await decide(email: emails[0], mustKeep: false, pattern: "daily activity statement")
        _ = try await decide(email: emails[1], mustKeep: false, pattern: "earnings notification")
        let remaining = try await decide(email: emails[2], mustKeep: true, pattern: "trade confirmation")

        XCTAssertTrue(remaining.isEmpty, "all three decisions must hold, not just the last")

        let stored = try await db.emails(accountId: accountId, senderEmail: "ib@example.com")
        let byId = Dictionary(uniqueKeysWithValues: stored.map { ($0.messageId, $0) })
        XCTAssertEqual(byId["a"]?.safetyTier, .safe)
        XCTAssertEqual(byId["b"]?.safetyTier, .safe, "the first decision was not reverted by later ones")
        XCTAssertEqual(byId["c"]?.safetyTier, .protected_)
    }

    func testTheTierIsActuallyPersistedNotJustComputed() async throws {
        // Guards the specific failure where the engine returns the right tier but the write does
        // not land, which would look identical from the UI.
        let email = reviewEmail("a", sender: "x@example.com", subject: "Statement 2026-08-27")
        try await db.upsertEmails([email])

        _ = try await decide(email: email, mustKeep: false, pattern: "statement")

        let stored = try await db.emails(accountId: accountId, senderEmail: "x@example.com")
        XCTAssertEqual(stored.first?.safetyTier, .safe)
        XCTAssertEqual(stored.first?.category, .notification, "the category is preserved")
    }
}
