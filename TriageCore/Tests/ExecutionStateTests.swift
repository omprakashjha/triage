import XCTest
@testable import TriageCore

/// Covers the pending-vs-executed distinction that makes undo possible, and the
/// action history that backs the History tab.
final class ExecutionStateTests: XCTestCase {

    private func makeAccountAndEmails(
        _ db: AppDatabase,
        messageIds: [String]
    ) async throws -> Int64 {
        var account = EmailAccount(email: "me@example.com", provider: .gmail, createdAt: Date())
        try await db.saveAccount(&account)
        let accountId = account.id!

        let emails = messageIds.map { id in
            EmailMetadata(
                accountId: accountId,
                messageId: id,
                sender: "Sender",
                senderEmail: "sender@example.com",
                subject: "Subject \(id)",
                date: Date(),
                category: .promotion,
                safetyTier: .safe,
                categoryConfidence: 0.85
            )
        }
        try await db.batchUpsertEmails(emails)
        return accountId
    }

    // MARK: - Pending vs executed

    func testMarkedButUnexecutedIsPending() async throws {
        let db = try AppDatabase.inMemory()
        let accountId = try await makeAccountAndEmails(db, messageIds: ["a", "b"])

        try await db.markEmailsActioned(messageIds: ["a"], accountId: accountId, action: .deleted)

        let pending = try await db.fetchMarkedEmails(accountId: accountId)
        XCTAssertEqual(pending.map(\.messageId), ["a"])
        XCTAssertTrue(pending[0].isPendingAction)
        XCTAssertFalse(pending[0].isExecuted)
    }

    func testExecutedEmailLeavesThePendingQueue() async throws {
        let db = try AppDatabase.inMemory()
        let accountId = try await makeAccountAndEmails(db, messageIds: ["a", "b"])

        try await db.markEmailsActioned(messageIds: ["a"], accountId: accountId, action: .deleted)
        try await db.markEmailsExecuted(messageIds: ["a"], accountId: accountId, action: .deleted)

        let pending = try await db.fetchMarkedEmails(accountId: accountId)
        XCTAssertTrue(
            pending.isEmpty,
            "executed mail must not reappear as pending, or it gets submitted to the provider twice"
        )
    }

    func testExecutedEmailIsExcludedFromWorkingViews() async throws {
        let db = try AppDatabase.inMemory()
        let accountId = try await makeAccountAndEmails(db, messageIds: ["a", "b"])

        try await db.markEmailsExecuted(messageIds: ["a"], accountId: accountId, action: .deleted)

        let working = try await db.fetchEmails(accountId: accountId, limit: 100)
        XCTAssertEqual(working.map(\.messageId), ["b"])

        let byTier = try await db.fetchEmailsByTier(accountId: accountId, tier: .safe)
        XCTAssertEqual(byTier.map(\.messageId), ["b"])
    }

    func testExecutedEmailIsStillRetrievableForUndo() async throws {
        let db = try AppDatabase.inMemory()
        let accountId = try await makeAccountAndEmails(db, messageIds: ["a", "b"])

        try await db.markEmailsExecuted(messageIds: ["a"], accountId: accountId, action: .deleted)

        // Retained rather than deleted — undo needs the row to restore local state.
        let all = try await db.fetchEmails(accountId: accountId, includeExecuted: true, limit: 100)
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.first(where: { $0.messageId == "a" })!.isExecuted)
    }

    func testClearingActionAlsoClearsExecutionState() async throws {
        let db = try AppDatabase.inMemory()
        let accountId = try await makeAccountAndEmails(db, messageIds: ["a"])

        try await db.markEmailsExecuted(messageIds: ["a"], accountId: accountId, action: .deleted)
        // This is what undo calls.
        try await db.markEmailsActioned(messageIds: ["a"], accountId: accountId, action: nil)

        let restored = try await db.fetchEmails(accountId: accountId, limit: 100)
        XCTAssertEqual(restored.count, 1, "undone mail must return to the working views")
        XCTAssertFalse(restored[0].isExecuted)
        XCTAssertNil(restored[0].actionTaken)
    }

    // MARK: - Action history

    func testActionHistoryIsScopedToAccountAndOrderedNewestFirst() async throws {
        let db = try AppDatabase.inMemory()
        let accountId = try await makeAccountAndEmails(db, messageIds: ["a"])

        var other = EmailAccount(email: "other@example.com", provider: .gmail, createdAt: Date())
        try await db.saveAccount(&other)

        var older = ActionLog(
            accountId: accountId, action: .archived, messageIds: ["a"], messageCount: 1,
            executedAt: Date().addingTimeInterval(-3600), description: "Older"
        )
        var newer = ActionLog(
            accountId: accountId, action: .deleted, messageIds: ["a"], messageCount: 1,
            executedAt: Date(), description: "Newer"
        )
        var foreign = ActionLog(
            accountId: other.id!, action: .deleted, messageIds: ["z"], messageCount: 1,
            description: "Other account"
        )
        try await db.logAction(&older)
        try await db.logAction(&newer)
        try await db.logAction(&foreign)

        let history = try await db.fetchActionHistory(accountId: accountId)
        XCTAssertEqual(history.map(\.description), ["Newer", "Older"])
    }

    func testFetchActionById() async throws {
        let db = try AppDatabase.inMemory()
        let accountId = try await makeAccountAndEmails(db, messageIds: ["a"])

        var log = ActionLog(
            accountId: accountId, action: .deleted, messageIds: ["a"], messageCount: 1,
            description: "Deleted 1 Promotion emails"
        )
        try await db.logAction(&log)

        let found = try await db.fetchAction(id: log.id!)
        XCTAssertEqual(found?.description, "Deleted 1 Promotion emails")
        XCTAssertFalse(found!.isReversed)

        try await db.markActionReversed(actionId: log.id!)
        let reversed = try await db.fetchAction(id: log.id!)
        XCTAssertTrue(reversed!.isReversed)
        XCTAssertNotNil(reversed!.reversedAt)
    }
}
