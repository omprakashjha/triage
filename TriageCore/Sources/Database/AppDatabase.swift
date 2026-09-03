import Foundation
import GRDB

/// Central database manager using GRDB with migrations
public final class AppDatabase: Sendable {
    private let dbWriter: any DatabaseWriter

    /// Shared database instance (singleton for app lifetime)
    private static var _shared: AppDatabase?

    public static func shared() throws -> AppDatabase {
        if let existing = _shared { return existing }
        let db = try AppDatabase(path: AppDatabase.defaultDatabasePath())
        _shared = db
        return db
    }

    /// For testing: create in-memory database
    public static func inMemory() throws -> AppDatabase {
        let dbQueue = try DatabaseQueue(configuration: Self.makeConfiguration())
        let db = AppDatabase(dbWriter: dbQueue)
        try db.migrate()
        return db
    }

    private init(path: String) throws {
        let dbQueue = try DatabaseQueue(path: path, configuration: Self.makeConfiguration())
        self.dbWriter = dbQueue
        try migrate()
    }

    private init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    private static func makeConfiguration() -> Configuration {
        var config = Configuration()
        #if DEBUG
        config.prepareDatabase { db in
            db.trace { print("SQL: \($0)") }
        }
        #endif
        return config
    }

    /// Default database path in Application Support
    private static func defaultDatabasePath() throws -> String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Triage", isDirectory: true)

        try FileManager.default.createDirectory(
            at: appSupport,
            withIntermediateDirectories: true
        )

        return appSupport.appendingPathComponent("triage.sqlite").path
    }

    // MARK: - Migrations

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        // NOTE: `eraseDatabaseOnSchemaChange` was deliberately REMOVED.
        // It silently destroys the user's scanned mailbox (and their contact list,
        // which needs network calls to rebuild) on any schema edit during development.
        // Additive migrations below are cheap to write and non-destructive.

        migrator.registerMigration("v1_initial") { db in
            // Accounts table
            try db.create(table: "emailAccount") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("email", .text).notNull().unique()
                t.column("provider", .text).notNull()
                t.column("displayName", .text)
                t.column("lastSyncDate", .datetime)
                t.column("lastHistoryId", .text)
                t.column("isActive", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .datetime).notNull()
            }

            // Email metadata table
            try db.create(table: "emailMetadata") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("accountId", .integer).notNull()
                    .references("emailAccount", onDelete: .cascade)
                t.column("messageId", .text).notNull()
                t.column("threadId", .text)
                t.column("sender", .text).notNull()
                t.column("senderEmail", .text).notNull()
                t.column("subject", .text).notNull()
                t.column("date", .datetime).notNull()
                t.column("snippet", .text)
                t.column("hasListUnsubscribe", .boolean).notNull().defaults(to: false)
                t.column("listUnsubscribeHeader", .text)
                t.column("replyTo", .text)
                t.column("labels", .text)  // JSON encoded array
                t.column("isUnread", .boolean).notNull().defaults(to: true)
                t.column("category", .text)
                t.column("safetyTier", .text)
                t.column("categoryConfidence", .double)
                t.column("actionTaken", .text)
                t.column("actionDate", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()

                // Unique constraint: one record per message per account
                t.uniqueKey(["accountId", "messageId"])
            }

            // Indexes for common queries
            try db.create(
                index: "idx_emailMetadata_accountId_category",
                on: "emailMetadata",
                columns: ["accountId", "category"]
            )
            try db.create(
                index: "idx_emailMetadata_senderEmail",
                on: "emailMetadata",
                columns: ["senderEmail"]
            )
            try db.create(
                index: "idx_emailMetadata_date",
                on: "emailMetadata",
                columns: ["date"]
            )
            try db.create(
                index: "idx_emailMetadata_isUnread",
                on: "emailMetadata",
                columns: ["isUnread"]
            )

            // Action log table
            try db.create(table: "actionLog") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("accountId", .integer).notNull()
                    .references("emailAccount", onDelete: .cascade)
                t.column("action", .text).notNull()
                t.column("messageIds", .text).notNull()  // JSON encoded array
                t.column("messageCount", .integer).notNull()
                t.column("isReversible", .boolean).notNull().defaults(to: true)
                t.column("isReversed", .boolean).notNull().defaults(to: false)
                t.column("executedAt", .datetime).notNull()
                t.column("reversedAt", .datetime)
                t.column("description", .text).notNull()
            }
        }

        migrator.registerMigration("v2_contacts_and_reason") { db in
            // Persisted contact list. Without this, contact detection has to re-run
            // network calls on every scan, and an empty set disables the protected tier.
            try db.create(table: "knownContact") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("accountId", .integer).notNull()
                    .references("emailAccount", onDelete: .cascade)
                t.column("email", .text).notNull()
                t.column("source", .text).notNull()
                t.column("occurrences", .integer).notNull().defaults(to: 1)
                t.column("addedAt", .datetime).notNull()

                t.uniqueKey(["accountId", "email"])
            }

            try db.create(
                index: "idx_knownContact_accountId",
                on: "knownContact",
                columns: ["accountId"]
            )

            // The engine already computes a human-readable reason for every decision;
            // it was being discarded instead of stored, so the UI could never show it.
            try db.alter(table: "emailMetadata") { t in
                t.add(column: "categoryReason", .text)
            }
        }

        try migrator.migrate(dbWriter)
    }
}

// MARK: - Account Operations

extension AppDatabase {
    public func fetchAllAccounts() async throws -> [EmailAccount] {
        try await dbWriter.read { db in
            try EmailAccount
                .filter(EmailAccount.Columns.isActive == true)
                .fetchAll(db)
        }
    }

    public func saveAccount(_ account: inout EmailAccount) async throws {
        let accountToSave = account
        let saved = try await dbWriter.write { db -> EmailAccount in
            try accountToSave.inserted(db)
        }
        account = saved
    }

    public func updateSyncState(accountId: Int64, historyId: String?, syncDate: Date) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE emailAccount
                    SET lastHistoryId = ?, lastSyncDate = ?
                    WHERE id = ?
                    """,
                arguments: [historyId, syncDate, accountId]
            )
        }
    }
}

// MARK: - Email Metadata Operations

extension AppDatabase {
    /// Bulk insert/update email metadata (upsert on accountId + messageId)
    public func upsertEmails(_ emails: [EmailMetadata]) async throws {
        try await dbWriter.write { db in
            for email in emails {
                // Use INSERT OR REPLACE to handle the unique constraint
                try email.upsert(db)
            }
        }
    }

    /// Batch upsert for better performance with large sets
    public func batchUpsertEmails(_ emails: [EmailMetadata], batchSize: Int = 500) async throws {
        let batches = stride(from: 0, to: emails.count, by: batchSize).map {
            Array(emails[$0..<min($0 + batchSize, emails.count)])
        }

        for batch in batches {
            try await dbWriter.write { db in
                for var email in batch {
                    email.updatedAt = Date()
                    try email.upsert(db)
                }
            }
        }
    }

    public func fetchEmails(
        accountId: Int64,
        category: EmailCategory? = nil,
        unreadOnly: Bool = false,
        limit: Int = 100,
        offset: Int = 0
    ) async throws -> [EmailMetadata] {
        try await dbWriter.read { db in
            var query = EmailMetadata
                .filter(EmailMetadata.Columns.accountId == accountId)

            if let category {
                query = query.filter(EmailMetadata.Columns.category == category.rawValue)
            }
            if unreadOnly {
                query = query.filter(EmailMetadata.Columns.isUnread == true)
            }

            return try query
                .order(EmailMetadata.Columns.date.desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    public func emailCount(accountId: Int64) async throws -> Int {
        try await dbWriter.read { db in
            try EmailMetadata
                .filter(EmailMetadata.Columns.accountId == accountId)
                .fetchCount(db)
        }
    }

    public func fetchEmailsByTier(accountId: Int64, tier: SafetyTier, limit: Int = 100) async throws -> [EmailMetadata] {
        try await dbWriter.read { db in
            try EmailMetadata
                .filter(EmailMetadata.Columns.accountId == accountId)
                .filter(EmailMetadata.Columns.safetyTier == tier.rawValue)
                .order(EmailMetadata.Columns.date.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func findSimilarBySubject(accountId: Int64, subject: String, limit: Int = 500) async throws -> [EmailMetadata] {
        try await dbWriter.read { db in
            try EmailMetadata
                .filter(EmailMetadata.Columns.accountId == accountId)
                .filter(EmailMetadata.Columns.subject == subject)
                .order(EmailMetadata.Columns.date.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func fetchMarkedEmails(accountId: Int64) async throws -> [EmailMetadata] {
        try await dbWriter.read { db in
            try EmailMetadata
                .filter(EmailMetadata.Columns.accountId == accountId)
                .filter(EmailMetadata.Columns.actionTaken != nil)
                .order(EmailMetadata.Columns.date.desc)
                .fetchAll(db)
        }
    }

    public func deleteAccount(accountId: Int64) async throws {
        try await dbWriter.write { db in
            // Emails are cascade-deleted due to foreign key
            try db.execute(sql: "DELETE FROM emailAccount WHERE id = ?", arguments: [accountId])
        }
    }

    public func removeEmails(messageIds: [String], accountId: Int64) async throws {
        guard !messageIds.isEmpty else { return }
        try await dbWriter.write { db in
            let placeholders = messageIds.map { _ in "?" }.joined(separator: ",")
            var arguments: [DatabaseValueConvertible] = [accountId]
            arguments.append(contentsOf: messageIds)
            try db.execute(
                sql: "DELETE FROM emailMetadata WHERE accountId = ? AND messageId IN (\(placeholders))",
                arguments: StatementArguments(arguments)
            )
        }
    }

    public func categoryBreakdown(accountId: Int64) async throws -> [EmailCategory: Int] {
        try await dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT category, COUNT(*) as count
                FROM emailMetadata
                WHERE accountId = ? AND category IS NOT NULL
                GROUP BY category
                """,
                arguments: [accountId]
            )
            var result: [EmailCategory: Int] = [:]
            for row in rows {
                if let rawCategory: String = row["category"],
                   let category = EmailCategory(rawValue: rawCategory) {
                    result[category] = row["count"]
                }
            }
            return result
        }
    }

    /// Get the most recent message date for an account (for incremental sync)
    public func latestMessageDate(accountId: Int64) async throws -> Date? {
        try await dbWriter.read { db in
            try EmailMetadata
                .filter(EmailMetadata.Columns.accountId == accountId)
                .select(max(EmailMetadata.Columns.date))
                .fetchOne(db)
        }
    }

    /// Update categorization results for a batch of emails
    public func updateCategories(_ results: [CategorizationResult], accountId: Int64) async throws {
        try await dbWriter.write { db in
            for result in results {
                try db.execute(
                    sql: """
                        UPDATE emailMetadata
                        SET category = ?, safetyTier = ?, categoryConfidence = ?,
                            categoryReason = ?, updatedAt = ?
                        WHERE messageId = ? AND accountId = ?
                        """,
                    arguments: [
                        result.category.rawValue,
                        result.safetyTier.rawValue,
                        result.confidence,
                        result.reason,
                        Date(),
                        result.messageId,
                        accountId
                    ]
                )
            }
        }
    }

    /// Fetch uncategorized emails for an account
    public func fetchUncategorizedEmails(accountId: Int64, limit: Int = 1000) async throws -> [EmailMetadata] {
        try await dbWriter.read { db in
            try EmailMetadata
                .filter(EmailMetadata.Columns.accountId == accountId)
                .filter(EmailMetadata.Columns.category == nil)
                .order(EmailMetadata.Columns.date.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Get full stats for an account (total, uncategorized, per-category, per-tier)
    public func accountStats(accountId: Int64) async throws -> AccountStats {
        try await dbWriter.read { db in
            let total = try EmailMetadata
                .filter(EmailMetadata.Columns.accountId == accountId)
                .fetchCount(db)

            let unread = try EmailMetadata
                .filter(EmailMetadata.Columns.accountId == accountId)
                .filter(EmailMetadata.Columns.isUnread == true)
                .fetchCount(db)

            let uncategorized = try EmailMetadata
                .filter(EmailMetadata.Columns.accountId == accountId)
                .filter(EmailMetadata.Columns.category == nil)
                .fetchCount(db)

            let categoryRows = try Row.fetchAll(db, sql: """
                SELECT category, COUNT(*) as count
                FROM emailMetadata
                WHERE accountId = ? AND category IS NOT NULL
                GROUP BY category
                """, arguments: [accountId])

            var categories: [EmailCategory: Int] = [:]
            for row in categoryRows {
                if let raw: String = row["category"],
                   let cat = EmailCategory(rawValue: raw) {
                    categories[cat] = row["count"]
                }
            }

            let tierRows = try Row.fetchAll(db, sql: """
                SELECT safetyTier, COUNT(*) as count
                FROM emailMetadata
                WHERE accountId = ? AND safetyTier IS NOT NULL
                GROUP BY safetyTier
                """, arguments: [accountId])

            var tiers: [SafetyTier: Int] = [:]
            for row in tierRows {
                if let raw: String = row["safetyTier"],
                   let tier = SafetyTier(rawValue: raw) {
                    tiers[tier] = row["count"]
                }
            }

            return AccountStats(
                totalEmails: total,
                unreadEmails: unread,
                uncategorizedEmails: uncategorized,
                categoryBreakdown: categories,
                tierBreakdown: tiers
            )
        }
    }
}

// MARK: - Known Contact Operations

extension AppDatabase {
    /// The lowercased address set used to drive the protected tier.
    public func knownContactEmails(accountId: Int64) async throws -> Set<String> {
        try await dbWriter.read { db in
            let emails = try String.fetchAll(
                db,
                sql: "SELECT email FROM knownContact WHERE accountId = ?",
                arguments: [accountId]
            )
            return Set(emails.map { $0.lowercased() })
        }
    }

    public func fetchKnownContacts(accountId: Int64) async throws -> [KnownContact] {
        try await dbWriter.read { db in
            try KnownContact
                .filter(KnownContact.Columns.accountId == accountId)
                .order(KnownContact.Columns.occurrences.desc)
                .fetchAll(db)
        }
    }

    /// Upsert detected contacts.
    ///
    /// A `manual` entry is never downgraded by re-detection — the user pinning an
    /// address outranks any heuristic that later disagrees.
    public func saveKnownContacts(_ contacts: [KnownContact]) async throws {
        guard !contacts.isEmpty else { return }
        try await dbWriter.write { db in
            for contact in contacts {
                try db.execute(
                    sql: """
                        INSERT INTO knownContact (accountId, email, source, occurrences, addedAt)
                        VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(accountId, email) DO UPDATE SET
                            occurrences = knownContact.occurrences + excluded.occurrences,
                            source = CASE
                                WHEN knownContact.source = 'manual' THEN 'manual'
                                ELSE excluded.source
                            END
                        """,
                    arguments: [
                        contact.accountId,
                        contact.email.lowercased(),
                        contact.source.rawValue,
                        contact.occurrences,
                        contact.addedAt
                    ]
                )
            }
        }
    }

    /// Pin an address by hand so its mail is always protected.
    public func addManualContact(email: String, accountId: Int64) async throws {
        try await saveKnownContacts([
            KnownContact(accountId: accountId, email: email, source: .manual, occurrences: 1)
        ])
    }

    public func removeKnownContact(email: String, accountId: Int64) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: "DELETE FROM knownContact WHERE accountId = ? AND LOWER(email) = ?",
                arguments: [accountId, email.lowercased()]
            )
        }
    }

    /// Senders of mail that Gmail itself classified as personal.
    ///
    /// Gmail's own `CATEGORY_PERSONAL` label is a useful independent signal. The label
    /// list is stored as JSON, so this filters in Swift rather than in SQL.
    public func sendersWithGmailPersonalLabel(accountId: Int64, limit: Int = 20000) async throws -> [String: Int] {
        let emails = try await fetchEmails(accountId: accountId, limit: limit, offset: 0)
        var counts: [String: Int] = [:]
        for email in emails {
            guard let labels = email.labels else { continue }
            guard labels.contains("CATEGORY_PERSONAL") else { continue }
            counts[email.senderEmail.lowercased(), default: 0] += 1
        }
        return counts
    }

    /// The review queue, weakest-confidence first.
    ///
    /// Ascending confidence is the correct order for human review: it puts the
    /// engine's least certain decisions in front of the user first, instead of
    /// burying them under decisions that needed no attention.
    public func fetchEmailsForReview(
        accountId: Int64,
        limit: Int = 500
    ) async throws -> [EmailMetadata] {
        try await dbWriter.read { db in
            try EmailMetadata
                .filter(EmailMetadata.Columns.accountId == accountId)
                .filter(EmailMetadata.Columns.safetyTier == SafetyTier.review.rawValue)
                .order(
                    EmailMetadata.Columns.categoryConfidence.ascNullsLast,
                    EmailMetadata.Columns.date.desc
                )
                .limit(limit)
                .fetchAll(db)
        }
    }
}

/// Stats summary for an account
public struct AccountStats: Sendable {
    public let totalEmails: Int
    public let unreadEmails: Int
    public let uncategorizedEmails: Int
    public let categoryBreakdown: [EmailCategory: Int]
    public let tierBreakdown: [SafetyTier: Int]

    public var categorizedEmails: Int { totalEmails - uncategorizedEmails }
    public var safeToAction: Int { tierBreakdown[.safe] ?? 0 }
    public var needsReview: Int { tierBreakdown[.review] ?? 0 }
    public var protected_: Int { tierBreakdown[.protected_] ?? 0 }
}

// MARK: - Action Log Operations

extension AppDatabase {
    /// Mark emails as having been acted upon
    public func markEmailsActioned(messageIds: [String], accountId: Int64, action: EmailAction?) async throws {
        guard !messageIds.isEmpty else { return }
        let placeholders = messageIds.map { _ in "?" }.joined(separator: ",")

        try await dbWriter.write { db in
            if let action {
                var arguments: StatementArguments = [action.rawValue, Date(), Date(), accountId]
                for id in messageIds { arguments += [id] }
                try db.execute(
                    sql: """
                        UPDATE emailMetadata
                        SET actionTaken = ?, actionDate = ?, updatedAt = ?
                        WHERE accountId = ? AND messageId IN (\(placeholders))
                        """,
                    arguments: arguments
                )
            } else {
                var arguments: StatementArguments = [Date(), accountId]
                for id in messageIds { arguments += [id] }
                try db.execute(
                    sql: """
                        UPDATE emailMetadata
                        SET actionTaken = NULL, actionDate = NULL, updatedAt = ?
                        WHERE accountId = ? AND messageId IN (\(placeholders))
                        """,
                    arguments: arguments
                )
            }
        }
    }

    public func logAction(_ action: inout ActionLog) async throws {
        let actionToSave = action
        let saved = try await dbWriter.write { db -> ActionLog in
            try actionToSave.inserted(db)
        }
        action = saved
    }

    public func fetchRecentActions(limit: Int = 20) async throws -> [ActionLog] {
        try await dbWriter.read { db in
            try ActionLog
                .order(ActionLog.Columns.executedAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func markActionReversed(actionId: Int64) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE actionLog
                    SET isReversed = 1, reversedAt = ?
                    WHERE id = ?
                    """,
                arguments: [Date(), actionId]
            )
        }
    }
}
