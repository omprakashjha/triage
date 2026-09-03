import Foundation

/// High-level service that coordinates Gmail API fetching with local database storage.
/// Handles both full sync and incremental sync via Gmail History API.
public actor GmailService {
    private let client: GmailAPIClient
    private let database: AppDatabase

    public init(client: GmailAPIClient, database: AppDatabase) {
        self.client = client
        self.database = database
    }

    // MARK: - Full Sync

    /// Fetch all email metadata, yielding progress updates.
    /// If incremental is true and we have a historyId, uses history API instead of full re-fetch.
    public func fetchAllMetadata(
        accountId: Int64,
        lastHistoryId: String? = nil,
        incremental: Bool = true,
        scope: ScanScope = .unreadOnly
    ) -> AsyncThrowingStream<ScanProgress, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    if incremental, let historyId = lastHistoryId {
                        try await self.performIncrementalSync(
                            accountId: accountId,
                            historyId: historyId,
                            scope: scope,
                            continuation: continuation
                        )
                    } else {
                        try await self.performFullSync(
                            accountId: accountId,
                            scope: scope,
                            continuation: continuation
                        )
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // For AppState compatibility (no accountId version)
    public func fetchAllMetadata(incremental: Bool = true) -> AsyncThrowingStream<ScanProgress, Error> {
        fetchAllMetadata(accountId: 0, lastHistoryId: nil, incremental: false)
    }

    // MARK: - Full Sync Implementation

    private func performFullSync(
        accountId: Int64,
        scope: ScanScope,
        continuation: AsyncThrowingStream<ScanProgress, Error>.Continuation
    ) async throws {
        // Step 1: Get all message IDs
        continuation.yield(ScanProgress(total: 0, fetched: 0, status: .fetchingList))

        let messageIds = try await client.listAllMessageIds(query: scope.gmailQuery)
        let total = messageIds.count

        if total == 0 {
            continuation.yield(ScanProgress(total: 0, fetched: 0, status: .completed))
            continuation.finish()
            return
        }

        // Step 2: Fetch metadata in batches
        continuation.yield(ScanProgress(total: total, fetched: 0, status: .fetchingMetadata))

        var fetched = 0
        let batchStream = client.batchGetMessages(ids: messageIds)

        for try await batch in batchStream {
            let emails = batch.compactMap { message -> EmailMetadata? in
                self.convertToMetadata(message: message, accountId: accountId)
            }

            // Store in database
            try await database.batchUpsertEmails(emails)
            fetched += batch.count

            continuation.yield(ScanProgress(total: total, fetched: fetched, status: .fetchingMetadata))
        }

        // Step 3: Update sync state with latest historyId
        let profile = try await client.getProfile()
        if let historyId = profile.historyId {
            try await database.updateSyncState(
                accountId: accountId,
                historyId: historyId,
                syncDate: Date()
            )
        }

        continuation.yield(ScanProgress(total: total, fetched: fetched, status: .completed))
        continuation.finish()
    }

    // MARK: - Incremental Sync Implementation

    private func performIncrementalSync(
        accountId: Int64,
        historyId: String,
        scope: ScanScope,
        continuation: AsyncThrowingStream<ScanProgress, Error>.Continuation
    ) async throws {
        continuation.yield(ScanProgress(total: 0, fetched: 0, status: .fetchingList))

        do {
            let historyRecords = try await client.listAllHistory(startHistoryId: historyId)

            // Collect new message IDs from history
            var newMessageIds: Set<String> = []
            var deletedMessageIds: Set<String> = []

            for record in historyRecords {
                if let added = record.messagesAdded {
                    for msg in added {
                        newMessageIds.insert(msg.message.id)
                    }
                }
                if let deleted = record.messagesDeleted {
                    for msg in deleted {
                        deletedMessageIds.insert(msg.message.id)
                    }
                }
            }

            // Remove deleted messages from new set
            newMessageIds.subtract(deletedMessageIds)

            let total = newMessageIds.count
            if total == 0 {
                // No new messages, just update sync state
                let profile = try await client.getProfile()
                if let newHistoryId = profile.historyId {
                    try await database.updateSyncState(
                        accountId: accountId,
                        historyId: newHistoryId,
                        syncDate: Date()
                    )
                }
                continuation.yield(ScanProgress(total: 0, fetched: 0, status: .completed))
                continuation.finish()
                return
            }

            // Fetch metadata for new messages
            continuation.yield(ScanProgress(total: total, fetched: 0, status: .fetchingMetadata))

            var fetched = 0
            let ids = Array(newMessageIds)
            let batchStream = client.batchGetMessages(ids: ids)

            for try await batch in batchStream {
                // The History API returns every added message regardless of the query
                // used for the full sync, so the scope filter has to be re-applied here
                // or the local database drifts out of agreement with itself.
                let emails = batch.compactMap { message -> EmailMetadata? in
                    guard scope.includes(
                        labelIds: message.labelIds,
                        isUnread: message.isUnread,
                        date: message.parsedDate ?? Date()
                    ) else { return nil }
                    return self.convertToMetadata(message: message, accountId: accountId)
                }

                try await database.batchUpsertEmails(emails)
                fetched += batch.count

                continuation.yield(ScanProgress(total: total, fetched: fetched, status: .fetchingMetadata))
            }

            // Update sync state
            let profile = try await client.getProfile()
            if let newHistoryId = profile.historyId {
                try await database.updateSyncState(
                    accountId: accountId,
                    historyId: newHistoryId,
                    syncDate: Date()
                )
            }

            continuation.yield(ScanProgress(total: total, fetched: fetched, status: .completed))
            continuation.finish()

        } catch let error as APIError {
            // If historyId is too old (404), fall back to full sync
            if case .httpError(statusCode: 404, _) = error {
                try await performFullSync(accountId: accountId, scope: scope, continuation: continuation)
            } else {
                throw error
            }
        }
    }

    // MARK: - Contact Detection

    /// Build a contact list from the user's own SENT mail.
    ///
    /// Anyone the user has written to is a real correspondent — this is the strongest
    /// signal available for the protected tier, and far more reliable than guessing
    /// from inbound patterns. Capped because a long-lived mailbox can hold tens of
    /// thousands of sent messages and the contact set saturates quickly.
    ///
    /// `ownAddress` is excluded: the user is not their own contact, and self-addressed
    /// mail (notes-to-self, mailing list echoes) would otherwise dominate the counts.
    public func fetchSentMailContacts(
        accountId: Int64,
        ownAddress: String,
        maxMessages: Int = 2000
    ) async throws -> [KnownContact] {
        let ids = try await client.listAllMessageIds(query: "in:sent")
        guard !ids.isEmpty else { return [] }

        let capped = Array(ids.prefix(maxMessages))
        let own = ownAddress.lowercased()

        var counts: [String: Int] = [:]
        let stream = client.batchGetMessages(ids: capped)
        for try await batch in stream {
            for message in batch {
                for address in message.recipientAddresses {
                    let normalized = address.lowercased()
                    guard normalized != own, normalized.contains("@") else { continue }
                    counts[normalized, default: 0] += 1
                }
            }
        }

        return counts.map { email, count in
            KnownContact(
                accountId: accountId,
                email: email,
                source: .sentMail,
                occurrences: count
            )
        }
    }

    // MARK: - Conversion

    private func convertToMetadata(message: GmailMessage, accountId: Int64) -> EmailMetadata? {
        guard let parsed = message.parsedSender else { return nil }

        let listUnsubscribe = message.listUnsubscribe
        let date = message.parsedDate ?? Date()

        return EmailMetadata(
            accountId: accountId,
            messageId: message.id,
            threadId: message.threadId,
            sender: parsed.name,
            senderEmail: parsed.email,
            subject: message.subject ?? "(No Subject)",
            date: date,
            snippet: message.snippet,
            hasListUnsubscribe: listUnsubscribe != nil,
            listUnsubscribeHeader: listUnsubscribe,
            replyTo: message.replyTo,
            labels: message.labelIds,
            isUnread: message.isUnread
        )
    }
}
