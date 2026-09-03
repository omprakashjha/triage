import XCTest
@testable import TriageCore

final class AppDatabaseTests: XCTestCase {

    var database: AppDatabase!

    override func setUp() async throws {
        database = try AppDatabase.inMemory()
    }

    // MARK: - Account Tests

    func testInsertAndFetchAccount() async throws {
        var account = EmailAccount(
            email: "test@gmail.com",
            provider: .gmail,
            displayName: "Test User"
        )

        try await database.saveAccount(&account)
        XCTAssertNotNil(account.id)

        let accounts = try await database.fetchAllAccounts()
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts[0].email, "test@gmail.com")
        XCTAssertEqual(accounts[0].provider, .gmail)
    }

    func testUpdateSyncState() async throws {
        var account = EmailAccount(
            email: "test@gmail.com",
            provider: .gmail
        )
        try await database.saveAccount(&account)
        let accountId = account.id!

        try await database.updateSyncState(
            accountId: accountId,
            historyId: "12345",
            syncDate: Date()
        )

        let accounts = try await database.fetchAllAccounts()
        XCTAssertEqual(accounts[0].lastHistoryId, "12345")
        XCTAssertNotNil(accounts[0].lastSyncDate)
    }

    // MARK: - Email Metadata Tests

    func testBulkInsertEmails() async throws {
        var account = EmailAccount(email: "test@gmail.com", provider: .gmail)
        try await database.saveAccount(&account)
        let accountId = account.id!

        let emails = (0..<100).map { i in
            EmailMetadata(
                accountId: accountId,
                messageId: "msg_\(i)",
                sender: "Sender \(i)",
                senderEmail: "sender\(i)@example.com",
                subject: "Subject \(i)",
                date: Date().addingTimeInterval(Double(-i * 3600)),
                hasListUnsubscribe: i % 3 == 0,
                isUnread: true
            )
        }

        try await database.batchUpsertEmails(emails)

        let count = try await database.emailCount(accountId: accountId)
        XCTAssertEqual(count, 100)
    }

    func testUpsertDoesNotDuplicate() async throws {
        var account = EmailAccount(email: "test@gmail.com", provider: .gmail)
        try await database.saveAccount(&account)
        let accountId = account.id!

        let email = EmailMetadata(
            accountId: accountId,
            messageId: "msg_1",
            sender: "Test",
            senderEmail: "test@example.com",
            subject: "Hello",
            date: Date(),
            isUnread: true
        )

        try await database.batchUpsertEmails([email])
        try await database.batchUpsertEmails([email])

        let count = try await database.emailCount(accountId: accountId)
        XCTAssertEqual(count, 1)
    }

    func testFetchEmailsWithCategory() async throws {
        var account = EmailAccount(email: "test@gmail.com", provider: .gmail)
        try await database.saveAccount(&account)
        let accountId = account.id!

        let emails = [
            EmailMetadata(
                accountId: accountId,
                messageId: "msg_1",
                sender: "Newsletter",
                senderEmail: "news@example.com",
                subject: "Weekly Update",
                date: Date(),
                category: .newsletter
            ),
            EmailMetadata(
                accountId: accountId,
                messageId: "msg_2",
                sender: "Promo",
                senderEmail: "deals@shop.com",
                subject: "50% Off!",
                date: Date(),
                category: .promotion
            ),
            EmailMetadata(
                accountId: accountId,
                messageId: "msg_3",
                sender: "Friend",
                senderEmail: "friend@gmail.com",
                subject: "Hey!",
                date: Date(),
                category: .personal
            ),
        ]

        try await database.batchUpsertEmails(emails)

        let newsletters = try await database.fetchEmails(accountId: accountId, category: .newsletter)
        XCTAssertEqual(newsletters.count, 1)
        XCTAssertEqual(newsletters[0].senderEmail, "news@example.com")
    }

    func testCategoryBreakdown() async throws {
        var account = EmailAccount(email: "test@gmail.com", provider: .gmail)
        try await database.saveAccount(&account)
        let accountId = account.id!

        let emails = [
            EmailMetadata(accountId: accountId, messageId: "1", sender: "A", senderEmail: "a@x.com", subject: "S", date: Date(), category: .newsletter),
            EmailMetadata(accountId: accountId, messageId: "2", sender: "B", senderEmail: "b@x.com", subject: "S", date: Date(), category: .newsletter),
            EmailMetadata(accountId: accountId, messageId: "3", sender: "C", senderEmail: "c@x.com", subject: "S", date: Date(), category: .promotion),
            EmailMetadata(accountId: accountId, messageId: "4", sender: "D", senderEmail: "d@x.com", subject: "S", date: Date(), category: .personal),
        ]

        try await database.batchUpsertEmails(emails)

        let breakdown = try await database.categoryBreakdown(accountId: accountId)
        XCTAssertEqual(breakdown[.newsletter], 2)
        XCTAssertEqual(breakdown[.promotion], 1)
        XCTAssertEqual(breakdown[.personal], 1)
    }

    // MARK: - Action Log Tests

    func testLogAndFetchAction() async throws {
        var account = EmailAccount(email: "test@gmail.com", provider: .gmail)
        try await database.saveAccount(&account)
        let accountId = account.id!

        var action = ActionLog(
            accountId: accountId,
            action: .archived,
            messageIds: ["msg_1", "msg_2", "msg_3"],
            messageCount: 3,
            description: "Archived 3 newsletters"
        )

        try await database.logAction(&action)
        XCTAssertNotNil(action.id)

        let actions = try await database.fetchRecentActions()
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].messageCount, 3)
        XCTAssertEqual(actions[0].action, .archived)
    }

    func testMarkActionReversed() async throws {
        var account = EmailAccount(email: "test@gmail.com", provider: .gmail)
        try await database.saveAccount(&account)
        let accountId = account.id!

        var action = ActionLog(
            accountId: accountId,
            action: .deleted,
            messageIds: ["msg_1"],
            messageCount: 1,
            description: "Deleted 1 promotion"
        )
        try await database.logAction(&action)

        try await database.markActionReversed(actionId: action.id!)

        let actions = try await database.fetchRecentActions()
        XCTAssertTrue(actions[0].isReversed)
        XCTAssertNotNil(actions[0].reversedAt)
    }
}
