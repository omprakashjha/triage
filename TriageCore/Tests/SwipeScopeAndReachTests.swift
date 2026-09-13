import XCTest
@testable import TriageCore

/// The scope a swipe applies to, and the feedback that makes a pattern's reach visible.
final class SwipeScopeAndReachTests: XCTestCase {
    private var db: AppDatabase!
    private var accountId: Int64!

    override func setUp() async throws {
        db = try AppDatabase.inMemory()
        var account = EmailAccount(email: "me@example.com", provider: .gmail, createdAt: Date())
        try await db.saveAccount(&account)
        accountId = account.id!
    }

    private func email(
        _ id: String = UUID().uuidString,
        sender: String,
        subject: String
    ) -> EmailMetadata {
        EmailMetadata(
            accountId: accountId,
            messageId: id,
            threadId: "t",
            sender: "Name <\(sender)>",
            senderEmail: sender,
            subject: subject,
            date: Date()
        )
    }

    private func seed(sender: String, subject: String, count: Int = 1) async throws {
        for _ in 0..<count {
            try await db.upsertEmails([email(sender: sender, subject: subject)])
        }
    }

    // MARK: - What a swipe covers

    func testSwipeCoversTheSameSenderAndSubjectOnly() async throws {
        // The user's chosen scope, and the reason no new storage was needed: a correction whose
        // pattern is the whole subject already means "this sender, this subject". Recurring mail
        // — a monthly statement, a re-sent notice, a repeated survey — is decided once rather
        // than once per copy.
        let correction = UserCorrection(
            accountId: accountId,
            senderEmail: "info@email.ns.nl",
            subjectPattern: "Deel uw mening over Flex Dal Voordeel",
            category: .promotion,
            mustKeep: false
        )
        let engine = CorrectingEngine(base: RuleBasedEngine(), corrections: [correction])

        let results = try await engine.categorize(emails: [
            // Two copies of the decided subject.
            email("a", sender: "info@email.ns.nl", subject: "Deel uw mening over Flex Dal Voordeel"),
            email("b", sender: "info@email.ns.nl", subject: "Deel uw mening over Flex Dal Voordeel"),
            // Same sender, different subject — untouched.
            email("c", sender: "info@email.ns.nl", subject: "Uw factuur van maart"),
            // Same subject, different sender — untouched.
            email("d", sender: "other@example.com", subject: "Deel uw mening over Flex Dal Voordeel"),
        ])
        let byId = Dictionary(uniqueKeysWithValues: results.map { ($0.messageId, $0) })

        XCTAssertEqual(byId["a"]?.safetyTier, .safe)
        XCTAssertEqual(byId["b"]?.safetyTier, .safe, "repeats of the same subject are covered")
        XCTAssertNotEqual(byId["c"]?.safetyTier, .safe, "a different subject is not decided")
        XCTAssertNotEqual(byId["d"]?.safetyTier, .safe, "a different sender is not decided")
    }

    func testSwipeKeepProtectsTheSameSenderAndSubject() async throws {
        let correction = UserCorrection(
            accountId: accountId,
            senderEmail: "donotreply@interactivebrokers.com",
            subjectPattern: "Official Trade Confirmation",
            category: .transactional,
            mustKeep: true
        )
        let engine = CorrectingEngine(base: RuleBasedEngine(), corrections: [correction])

        let results = try await engine.categorize(emails: [
            email("a", sender: "donotreply@interactivebrokers.com",
                  subject: "Official Trade Confirmation for 12 September"),
            email("b", sender: "donotreply@interactivebrokers.com",
                  subject: "Daily Activity Statement"),
        ])
        let byId = Dictionary(uniqueKeysWithValues: results.map { ($0.messageId, $0) })

        XCTAssertEqual(byId["a"]?.safetyTier, .protected_)
        XCTAssertNotEqual(byId["b"]?.safetyTier, .protected_)
    }

    func testSwipePreservesTheCategoryItWasGiven() async throws {
        // A swipe decides an email's FATE, not its classification. Overwriting the category
        // would discard the model's reading for nothing.
        let correction = UserCorrection(
            accountId: accountId,
            senderEmail: "info@email.ns.nl",
            subjectPattern: "Maak kans op een jaar gratis treinen",
            category: .notification,
            mustKeep: false
        )
        let engine = CorrectingEngine(base: RuleBasedEngine(), corrections: [correction])
        let results = try await engine.categorize(emails: [
            email("a", sender: "info@email.ns.nl",
                  subject: "Maak kans op een jaar gratis treinen!")
        ])

        XCTAssertEqual(results[0].category, .notification)
        XCTAssertEqual(results[0].safetyTier, .safe)
    }

    // MARK: - Reach feedback

    func testReachReportsMatchingOutOfTotal() async throws {
        try await seed(sender: "info@email.ns.nl", subject: "Korting op reizen", count: 3)
        try await seed(sender: "info@email.ns.nl", subject: "Uw factuur van maart", count: 2)
        try await seed(sender: "other@example.com", subject: "Korting op reizen", count: 5)

        let narrow = try await db.subjectPatternReach(
            accountId: accountId, senderEmail: "info@email.ns.nl",
            subjectPattern: "Uw factuur van maart"
        )
        XCTAssertEqual(narrow.matching, 2)
        XCTAssertEqual(narrow.total, 5, "other senders are not counted")

        let wide = try await db.subjectPatternReach(
            accountId: accountId, senderEmail: "info@email.ns.nl", subjectPattern: "korting"
        )
        XCTAssertEqual(wide.matching, 3, "matching is case-insensitive")
    }

    func testReachIsZeroForAPatternThatMatchesNothing() async throws {
        try await seed(sender: "x@example.com", subject: "Hello", count: 4)
        let reach = try await db.subjectPatternReach(
            accountId: accountId, senderEmail: "x@example.com", subjectPattern: "jaarafrekening"
        )
        XCTAssertEqual(reach.matching, 0)
        XCTAssertEqual(reach.total, 4)
    }

    func testAnEmptyPatternReportsTheWholeSender() async throws {
        // An empty pattern is what a whole-sender correction does, so reporting 0 would
        // misdescribe it.
        try await seed(sender: "x@example.com", subject: "Hello", count: 4)
        let reach = try await db.subjectPatternReach(
            accountId: accountId, senderEmail: "x@example.com", subjectPattern: "  "
        )
        XCTAssertEqual(reach.matching, 4)
        XCTAssertEqual(reach.total, 4)
    }

    func testFullSubjectReachesOneWhileAWordReachesMany() async throws {
        // The distinction the prefilled field exists to teach: the full subject decides this
        // email, and deleting words is what turns it into a rule.
        try await seed(sender: "info@email.ns.nl", subject: "Korting: dagje uit in maart")
        try await seed(sender: "info@email.ns.nl", subject: "Korting: dagje uit in april")
        try await seed(sender: "info@email.ns.nl", subject: "Uw reisoverzicht")

        let exact = try await db.subjectPatternReach(
            accountId: accountId, senderEmail: "info@email.ns.nl",
            subjectPattern: "Korting: dagje uit in maart"
        )
        XCTAssertEqual(exact.matching, 1)

        let generalised = try await db.subjectPatternReach(
            accountId: accountId, senderEmail: "info@email.ns.nl",
            subjectPattern: "dagje uit"
        )
        XCTAssertEqual(generalised.matching, 2)
    }
}
