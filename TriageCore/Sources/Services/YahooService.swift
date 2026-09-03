import Foundation

/// High-level service that coordinates Yahoo IMAP fetching with local database storage.
public actor YahooService {
    private let client: IMAPClient
    private let database: AppDatabase

    public init(client: IMAPClient? = nil, database: AppDatabase) {
        self.client = client ?? IMAPClient()
        self.database = database
    }

    // MARK: - Connection

    /// Connect to Yahoo IMAP with app password
    public func connect(email: String, appPassword: String) async throws {
        try await client.connect(email: email, appPassword: appPassword)
    }

    /// Disconnect from Yahoo
    public func disconnect() async {
        await client.disconnect()
    }

    // MARK: - Sync

    /// Fetch all unread email metadata from Yahoo inbox
    public func fetchAllMetadata(accountId: Int64) -> AsyncThrowingStream<ScanProgress, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    // Select INBOX
                    continuation.yield(ScanProgress(total: 0, fetched: 0, status: .connecting))
                    let mailbox = try await self.client.selectMailbox("INBOX")

                    // Search for UNSEEN messages
                    continuation.yield(ScanProgress(total: 0, fetched: 0, status: .fetchingList))
                    let uids = try await self.client.searchUIDs(criteria: "UNSEEN")

                    let total = uids.count
                    if total == 0 {
                        continuation.yield(ScanProgress(total: 0, fetched: 0, status: .completed))
                        continuation.finish()
                        return
                    }

                    // Fetch metadata in batches
                    continuation.yield(ScanProgress(total: total, fetched: 0, status: .fetchingMetadata))
                    var fetched = 0

                    let stream = self.client.fetchAllMetadata(
                        uids: uids,
                        batchSize: 50,
                        delayBetweenBatches: 1.5  // Yahoo is strict on rate limits
                    )

                    for try await batch in stream {
                        let emails = batch.map { msg in
                            self.convertToMetadata(message: msg, accountId: accountId)
                        }

                        try await self.database.batchUpsertEmails(emails)
                        fetched += batch.count

                        continuation.yield(ScanProgress(total: total, fetched: fetched, status: .fetchingMetadata))
                    }

                    // Update sync state
                    try await self.database.updateSyncState(
                        accountId: accountId,
                        historyId: nil,  // IMAP doesn't have history IDs
                        syncDate: Date()
                    )

                    continuation.yield(ScanProgress(total: total, fetched: fetched, status: .completed))
                    continuation.finish()

                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Fetch contacts from Sent folder for importance detection
    public func fetchKnownContacts() async throws -> Set<String> {
        try await client.fetchSentRecipients(limit: 500)
    }

    // MARK: - Conversion

    private func convertToMetadata(message: IMAPMessageMetadata, accountId: Int64) -> EmailMetadata {
        EmailMetadata(
            accountId: accountId,
            messageId: String(message.uid),
            sender: message.sender,
            senderEmail: message.senderEmail,
            subject: message.subject,
            date: message.date,
            hasListUnsubscribe: message.hasListUnsubscribe,
            listUnsubscribeHeader: message.listUnsubscribeHeader,
            replyTo: message.replyTo,
            isUnread: true
        )
    }
}
