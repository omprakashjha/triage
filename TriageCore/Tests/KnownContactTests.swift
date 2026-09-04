import XCTest
@testable import TriageCore

/// Covers the contact-detection path that makes the `.protected_` tier reachable,
/// plus the confidence-ordered review queue.
final class KnownContactTests: XCTestCase {

    // MARK: - Address list parsing

    func testParseSingleAddress() {
        let result = EmailHeaderParser.parseAddressList("john@example.com")
        XCTAssertEqual(result, ["john@example.com"])
    }

    func testParseMultipleAddresses() {
        let result = EmailHeaderParser.parseAddressList(
            "John Doe <john@example.com>, jane@example.org"
        )
        XCTAssertEqual(result, ["john@example.com", "jane@example.org"])
    }

    func testParseAddressWithCommaInsideQuotedName() {
        // "Doe, John" contains a comma that must NOT split the field.
        let result = EmailHeaderParser.parseAddressList(
            "\"Doe, John\" <john@example.com>, jane@example.org"
        )
        XCTAssertEqual(result, ["john@example.com", "jane@example.org"])
    }

    func testParseAddressListIgnoresGarbage() {
        let result = EmailHeaderParser.parseAddressList("undisclosed-recipients:;, real@example.com")
        XCTAssertEqual(result, ["real@example.com"])
    }

    // MARK: - Contact persistence

    func testSaveAndLoadContacts() async throws {
        let db = try AppDatabase.inMemory()
        var account = EmailAccount(email: "me@example.com", provider: .gmail, createdAt: Date())
        try await db.saveAccount(&account)
        let accountId = account.id!

        try await db.saveKnownContacts([
            KnownContact(accountId: accountId, email: "Friend@Example.com", source: .sentMail, occurrences: 3),
            KnownContact(accountId: accountId, email: "boss@work.com", source: .sentMail, occurrences: 7),
        ])

        let emails = try await db.knownContactEmails(accountId: accountId)
        XCTAssertEqual(emails, ["friend@example.com", "boss@work.com"], "addresses must be normalized to lowercase")
    }

    func testOccurrencesAccumulateOnRepeatedDetection() async throws {
        let db = try AppDatabase.inMemory()
        var account = EmailAccount(email: "me@example.com", provider: .gmail, createdAt: Date())
        try await db.saveAccount(&account)
        let accountId = account.id!

        let contact = KnownContact(accountId: accountId, email: "friend@example.com", source: .sentMail, occurrences: 2)
        try await db.saveKnownContacts([contact])
        try await db.saveKnownContacts([contact])

        let stored = try await db.fetchKnownContacts(accountId: accountId)
        XCTAssertEqual(stored.count, 1, "unique constraint should collapse duplicates")
        XCTAssertEqual(stored[0].occurrences, 4)
    }

    func testManualContactIsNotDowngradedByRedetection() async throws {
        let db = try AppDatabase.inMemory()
        var account = EmailAccount(email: "me@example.com", provider: .gmail, createdAt: Date())
        try await db.saveAccount(&account)
        let accountId = account.id!

        try await db.addManualContact(email: "pinned@example.com", accountId: accountId)
        // A later detection pass reports the same address from a weaker source.
        try await db.saveKnownContacts([
            KnownContact(accountId: accountId, email: "pinned@example.com", source: .gmailPersonalLabel)
        ])

        let stored = try await db.fetchKnownContacts(accountId: accountId)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].source, .manual, "a user-pinned contact must outrank re-detection")
    }

    func testRemoveContact() async throws {
        let db = try AppDatabase.inMemory()
        var account = EmailAccount(email: "me@example.com", provider: .gmail, createdAt: Date())
        try await db.saveAccount(&account)
        let accountId = account.id!

        try await db.addManualContact(email: "gone@example.com", accountId: accountId)
        try await db.removeKnownContact(email: "GONE@example.com", accountId: accountId)

        let emails = try await db.knownContactEmails(accountId: accountId)
        XCTAssertTrue(emails.isEmpty, "removal must be case-insensitive")
    }

    // MARK: - The bug this whole path exists to fix

    func testContactsMakeProtectedTierReachable() async throws {
        // With an empty contact set (the previous production behaviour) nothing is
        // ever protected, no matter what the mail looks like.
        let blindEngine = RuleBasedEngine(knownContacts: [])
        let email = EmailMetadata(
            accountId: 1,
            messageId: "m1",
            sender: "A Friend",
            senderEmail: "friend@example.com",
            subject: "Lunch on Thursday?",
            date: Date()
        )

        let blindResults = try await blindEngine.categorize(emails: [email])
        XCTAssertNotEqual(blindResults[0].safetyTier, .protected_)

        let wiredEngine = RuleBasedEngine(knownContacts: ["friend@example.com"])
        let wiredResults = try await wiredEngine.categorize(emails: [email])
        XCTAssertEqual(wiredResults[0].category, .personal)
        XCTAssertEqual(wiredResults[0].safetyTier, .protected_)
    }

    // MARK: - Review queue ordering

    func testReviewQueueIsOrderedByAscendingConfidence() async throws {
        let db = try AppDatabase.inMemory()
        var account = EmailAccount(email: "me@example.com", provider: .gmail, createdAt: Date())
        try await db.saveAccount(&account)
        let accountId = account.id!

        let emails = [
            ("high", 0.9),
            ("low", 0.2),
            ("mid", 0.55),
        ].map { id, confidence in
            EmailMetadata(
                accountId: accountId,
                messageId: id,
                sender: id,
                senderEmail: "\(id)@example.com",
                subject: id,
                date: Date(),
                category: .unknown,
                safetyTier: .review,
                categoryConfidence: confidence
            )
        }
        try await db.batchUpsertEmails(emails)

        let queue = try await db.fetchEmailsForReview(accountId: accountId)
        XCTAssertEqual(
            queue.map(\.messageId),
            ["low", "mid", "high"],
            "least-confident decisions must reach the human first"
        )
    }
}
