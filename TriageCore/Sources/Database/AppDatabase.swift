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

        migrator.registerMigration("v3_execution_state") { db in
            // `actionTaken` was overloaded: it meant both "the user marked this" and
            // "this was already executed against the provider". With undo in play those
            // must be distinguishable, otherwise executed mail reappears in the pending
            // queue and undo cannot tell what it is reversing.
            //
            // nil        -> marked, not yet executed (pending)
            // non-nil    -> executed against the provider at this time
            try db.alter(table: "emailMetadata") { t in
                t.add(column: "actionExecutedAt", .datetime)
            }

            try db.create(
                index: "idx_emailMetadata_actionExecutedAt",
                on: "emailMetadata",
                columns: ["accountId", "actionExecutedAt"]
            )
        }

        migrator.registerMigration("v4_sender_rules") { db in
            // Standing per-sender decisions, re-applied on every scan. This is what
            // makes a triage decision durable instead of a one-off sweep.
            try db.create(table: "senderRule") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("accountId", .integer).notNull()
                    .references("emailAccount", onDelete: .cascade)
                t.column("pattern", .text).notNull()
                t.column("scope", .text).notNull()
                t.column("action", .text).notNull()
                t.column("minAgeDays", .integer)
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .datetime).notNull()

                t.uniqueKey(["accountId", "pattern", "scope"])
            }

            try db.create(
                index: "idx_senderRule_accountId",
                on: "senderRule",
                columns: ["accountId", "isEnabled"]
            )

            // Persisted category-level action rules (ActionRules), stored as JSON so
            // the struct can gain fields without another migration. Previously
            // ActionRules was Codable but always the hardcoded .default.
            try db.create(table: "accountSettings") { t in
                t.column("accountId", .integer).notNull().primaryKey()
                    .references("emailAccount", onDelete: .cascade)
                t.column("actionRulesJSON", .text)
                t.column("scanScope", .text)
                t.column("updatedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v5_unsubscribe") { db in
            // RFC 8058: a POST is only safe when the sender advertised one-click
            // support via List-Unsubscribe-Post. Stored per message so the sender
            // view can tell a one-click unsubscribe from one needing a browser.
            try db.alter(table: "emailMetadata") { t in
                t.add(column: "supportsOneClickUnsubscribe", .boolean)
                    .notNull()
                    .defaults(to: false)
            }

            // Attempts are recorded so a later scan can tell whether the sender
            // actually stopped — an ignored unsubscribe is otherwise invisible.
            try db.create(table: "unsubscribeAttempt") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("accountId", .integer).notNull()
                    .references("emailAccount", onDelete: .cascade)
                t.column("senderEmail", .text).notNull()
                t.column("attemptedAt", .datetime).notNull()
                t.column("method", .text).notNull()
                t.column("succeeded", .boolean).notNull()
                t.column("note", .text)

                t.uniqueKey(["accountId", "senderEmail"])
            }
        }

        migrator.registerMigration("v6_golden_labels") { db in
            // Human ground truth for measuring the engine. Sender-level, because the
            // top ~100 senders cover most of a large mailbox.
            try db.create(table: "goldenLabel") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("accountId", .integer).notNull()
                    .references("emailAccount", onDelete: .cascade)
                t.column("senderEmail", .text).notNull()
                t.column("expectedCategory", .text).notNull()
                t.column("disposition", .text).notNull()
                t.column("note", .text)
                t.column("labelledAt", .datetime).notNull()

                t.uniqueKey(["accountId", "senderEmail"])
            }
        }

        migrator.registerMigration("v7_sender_verdicts") { db in
            // Model verdicts, keyed by model AND prompt version so that changing either
            // re-classifies rather than silently reusing verdicts produced by something
            // else. A rescan then costs nothing for senders already judged.
            try db.create(table: "senderVerdict") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("accountId", .integer).notNull()
                    .references("emailAccount", onDelete: .cascade)
                t.column("senderEmail", .text).notNull()
                t.column("modelId", .text).notNull()
                t.column("promptVersion", .text).notNull()
                t.column("category", .text).notNull()
                t.column("mustKeep", .boolean).notNull()
                t.column("isRealPerson", .boolean).notNull()
                t.column("confidence", .double).notNull()
                t.column("reason", .text).notNull()
                t.column("createdAt", .datetime).notNull()

                t.uniqueKey(["accountId", "senderEmail", "modelId", "promptVersion"])
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
        includeExecuted: Bool = false,
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
            // Executed mail is retained for undo/history but must not appear in the
            // working views, or it gets planned and actioned a second time.
            if !includeExecuted {
                query = query.filter(EmailMetadata.Columns.actionExecutedAt == nil)
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
                .filter(EmailMetadata.Columns.actionExecutedAt == nil)
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

    /// Emails the user has marked but which have NOT yet been sent to the provider.
    ///
    /// Filtering on `actionExecutedAt == nil` is what stops already-executed mail from
    /// reappearing in the Pending Actions panel and being submitted twice.
    public func fetchMarkedEmails(accountId: Int64) async throws -> [EmailMetadata] {
        try await dbWriter.read { db in
            try EmailMetadata
                .filter(EmailMetadata.Columns.accountId == accountId)
                .filter(EmailMetadata.Columns.actionTaken != nil)
                .filter(EmailMetadata.Columns.actionExecutedAt == nil)
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

// MARK: - Sender Aggregation

extension AppDatabase {
    /// One row per unique sender, aggregated in SQL.
    ///
    /// Deliberately not built by loading every email into memory: a large mailbox has
    /// tens of thousands of messages but only a few hundred senders, and the whole
    /// point of the sender view is that it stays cheap on a big inbox.
    public func senderSummaries(
        accountId: Int64,
        limit: Int = 1000
    ) async throws -> [SenderSummary] {
        let contacts = try await knownContactEmails(accountId: accountId)

        return try await dbWriter.read { db in
            // Aggregates. Executed mail is excluded so acted-on senders drop off the list.
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    e.senderEmail AS senderEmail,
                    (
                        SELECT e2.sender FROM emailMetadata e2
                        WHERE e2.accountId = e.accountId
                          AND e2.senderEmail = e.senderEmail
                        ORDER BY e2.date DESC LIMIT 1
                    ) AS displayName,
                    COUNT(*) AS totalEmails,
                    SUM(CASE WHEN e.isUnread THEN 1 ELSE 0 END) AS unreadEmails,
                    MIN(e.date) AS firstSeen,
                    MAX(e.date) AS lastSeen,
                    MAX(CASE WHEN e.hasListUnsubscribe THEN 1 ELSE 0 END) AS hasUnsubscribe
                FROM emailMetadata e
                WHERE e.accountId = ? AND e.actionExecutedAt IS NULL
                GROUP BY e.senderEmail
                ORDER BY totalEmails DESC
                LIMIT ?
                """,
                arguments: [accountId, limit]
            )

            // Per-sender category and tier distribution, folded in Swift.
            let breakdown = try Row.fetchAll(db, sql: """
                SELECT senderEmail, category, safetyTier, COUNT(*) AS count
                FROM emailMetadata
                WHERE accountId = ? AND actionExecutedAt IS NULL
                GROUP BY senderEmail, category, safetyTier
                """,
                arguments: [accountId]
            )

            var categoryCounts: [String: [EmailCategory: Int]] = [:]
            var tiers: [String: Set<SafetyTier>] = [:]
            for row in breakdown {
                let sender: String = row["senderEmail"]
                let count: Int = row["count"] ?? 0
                if let raw: String = row["category"], let category = EmailCategory(rawValue: raw) {
                    categoryCounts[sender, default: [:]][category, default: 0] += count
                }
                if let raw: String = row["safetyTier"], let tier = SafetyTier(rawValue: raw) {
                    tiers[sender, default: []].insert(tier)
                }
            }

            return rows.map { row in
                let sender: String = row["senderEmail"]
                let dominant = categoryCounts[sender]?.max(by: { $0.value < $1.value })?.key
                return SenderSummary(
                    senderEmail: sender,
                    displayName: row["displayName"] ?? sender,
                    totalEmails: row["totalEmails"] ?? 0,
                    unreadEmails: row["unreadEmails"] ?? 0,
                    firstSeen: row["firstSeen"] ?? Date(),
                    lastSeen: row["lastSeen"] ?? Date(),
                    hasUnsubscribeOption: (row["hasUnsubscribe"] as Int? ?? 0) > 0,
                    dominantCategory: dominant,
                    strictestTier: Self.strictestTier(in: tiers[sender] ?? []),
                    isKnownContact: contacts.contains(sender.lowercased())
                )
            }
        }
    }

    /// Protected outranks review, which outranks safe — so a sender holding any
    /// protected mail is never shown as bulk-actionable.
    static func strictestTier(in tiers: Set<SafetyTier>) -> SafetyTier? {
        if tiers.contains(.protected_) { return .protected_ }
        if tiers.contains(.review) { return .review }
        if tiers.contains(.safe) { return .safe }
        return nil
    }

    /// Every unexecuted message id from a sender, for bulk marking.
    public func messageIds(accountId: Int64, senderEmail: String) async throws -> [String] {
        try await dbWriter.read { db in
            try String.fetchAll(db, sql: """
                SELECT messageId FROM emailMetadata
                WHERE accountId = ? AND LOWER(senderEmail) = ? AND actionExecutedAt IS NULL
                """,
                arguments: [accountId, senderEmail.lowercased()]
            )
        }
    }

    /// Message ids from a sender, keeping the newest `keepNewest` untouched.
    /// Backs "keep the last 3, delete the rest".
    public func messageIds(
        accountId: Int64,
        senderEmail: String,
        keepNewest: Int
    ) async throws -> [String] {
        try await dbWriter.read { db in
            try String.fetchAll(db, sql: """
                SELECT messageId FROM emailMetadata
                WHERE accountId = ? AND LOWER(senderEmail) = ? AND actionExecutedAt IS NULL
                ORDER BY date DESC
                LIMIT -1 OFFSET ?
                """,
                arguments: [accountId, senderEmail.lowercased(), keepNewest]
            )
        }
    }
}

// MARK: - Sender Rules

extension AppDatabase {
    public func fetchSenderRules(accountId: Int64) async throws -> [SenderRule] {
        try await dbWriter.read { db in
            try SenderRule
                .filter(SenderRule.Columns.accountId == accountId)
                .order(SenderRule.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    public func fetchEnabledSenderRules(accountId: Int64) async throws -> [SenderRule] {
        try await dbWriter.read { db in
            try SenderRule
                .filter(SenderRule.Columns.accountId == accountId)
                .filter(SenderRule.Columns.isEnabled == true)
                .fetchAll(db)
        }
    }

    /// Upsert a rule. Re-deciding a sender replaces the previous decision rather
    /// than stacking a second conflicting rule on top of it.
    public func saveSenderRule(_ rule: SenderRule) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO senderRule (accountId, pattern, scope, action, minAgeDays, isEnabled, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(accountId, pattern, scope) DO UPDATE SET
                        action = excluded.action,
                        minAgeDays = excluded.minAgeDays,
                        isEnabled = excluded.isEnabled
                    """,
                arguments: [
                    rule.accountId,
                    rule.pattern.lowercased(),
                    rule.scope.rawValue,
                    rule.action.rawValue,
                    rule.minAgeDays,
                    rule.isEnabled,
                    rule.createdAt
                ]
            )
        }
    }

    public func deleteSenderRule(id: Int64) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: "DELETE FROM senderRule WHERE id = ?", arguments: [id])
        }
    }

    public func setSenderRuleEnabled(id: Int64, isEnabled: Bool) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: "UPDATE senderRule SET isEnabled = ? WHERE id = ?",
                arguments: [isEnabled, id]
            )
        }
    }
}

// MARK: - Account Settings

extension AppDatabase {
    public func accountSettings(accountId: Int64) async throws -> AccountSettings {
        try await dbWriter.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT actionRulesJSON, scanScope FROM accountSettings WHERE accountId = ?",
                arguments: [accountId]
            ) else {
                return AccountSettings(accountId: accountId)
            }

            var rules = ActionRules.default
            if let json: String = row["actionRulesJSON"],
               let data = json.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(ActionRules.self, from: data) {
                rules = decoded
            }

            let scope = (row["scanScope"] as String?)
                .flatMap(ScanScope.init(rawValue:)) ?? .unreadOnly

            return AccountSettings(accountId: accountId, actionRules: rules, scanScope: scope)
        }
    }

    public func saveAccountSettings(_ settings: AccountSettings) async throws {
        let json = String(
            data: try JSONEncoder().encode(settings.actionRules),
            encoding: .utf8
        )
        try await dbWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO accountSettings (accountId, actionRulesJSON, scanScope, updatedAt)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(accountId) DO UPDATE SET
                        actionRulesJSON = excluded.actionRulesJSON,
                        scanScope = excluded.scanScope,
                        updatedAt = excluded.updatedAt
                    """,
                arguments: [settings.accountId, json, settings.scanScope.rawValue, Date()]
            )
        }
    }

    /// Emails eligible for automatic rule application.
    ///
    /// Excludes anything already marked or executed, and excludes the protected tier
    /// outright — a sender rule must never be able to action a contact's mail.
    public func fetchUnmarkedActionableEmails(
        accountId: Int64,
        limit: Int = 50000
    ) async throws -> [EmailMetadata] {
        try await dbWriter.read { db in
            try EmailMetadata
                .filter(EmailMetadata.Columns.accountId == accountId)
                .filter(EmailMetadata.Columns.actionTaken == nil)
                .filter(EmailMetadata.Columns.actionExecutedAt == nil)
                .filter(EmailMetadata.Columns.safetyTier != SafetyTier.protected_.rawValue)
                .order(EmailMetadata.Columns.date.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }
}

// MARK: - Unsubscribe

extension AppDatabase {
    /// The most recent unsubscribe header seen from a sender, with its one-click flag.
    ///
    /// Uses the newest message because senders rotate their unsubscribe URLs — an old
    /// header may point at a link that has already expired.
    public func latestUnsubscribeInfo(
        accountId: Int64,
        senderEmail: String
    ) async throws -> (header: String, supportsOneClick: Bool)? {
        try await dbWriter.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT listUnsubscribeHeader, supportsOneClickUnsubscribe
                FROM emailMetadata
                WHERE accountId = ? AND LOWER(senderEmail) = ?
                  AND listUnsubscribeHeader IS NOT NULL
                ORDER BY date DESC
                LIMIT 1
                """,
                arguments: [accountId, senderEmail.lowercased()]
            ) else { return nil }

            guard let header: String = row["listUnsubscribeHeader"] else { return nil }
            let oneClick = (row["supportsOneClickUnsubscribe"] as Bool?) ?? false
            return (header: header, supportsOneClick: oneClick)
        }
    }

    public func recordUnsubscribeAttempt(
        _ attempt: UnsubscribeAttempt,
        accountId: Int64
    ) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO unsubscribeAttempt
                        (accountId, senderEmail, attemptedAt, method, succeeded, note)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(accountId, senderEmail) DO UPDATE SET
                        attemptedAt = excluded.attemptedAt,
                        method = excluded.method,
                        succeeded = excluded.succeeded,
                        note = excluded.note
                    """,
                arguments: [
                    accountId,
                    attempt.senderEmail.lowercased(),
                    attempt.attemptedAt,
                    attempt.method,
                    attempt.succeeded,
                    attempt.note
                ]
            )
        }
    }

    public func fetchUnsubscribeAttempts(accountId: Int64) async throws -> [UnsubscribeAttempt] {
        try await dbWriter.read { db in
            try Row.fetchAll(db, sql: """
                SELECT senderEmail, attemptedAt, method, succeeded, note
                FROM unsubscribeAttempt
                WHERE accountId = ?
                ORDER BY attemptedAt DESC
                """,
                arguments: [accountId]
            ).map { row in
                UnsubscribeAttempt(
                    senderEmail: row["senderEmail"],
                    attemptedAt: row["attemptedAt"],
                    method: row["method"],
                    succeeded: row["succeeded"],
                    note: row["note"]
                )
            }
        }
    }

    /// Senders that kept sending after a successful unsubscribe.
    ///
    /// This is the verification step: an unsubscribe that quietly did nothing looks
    /// identical to one that worked until you check whether mail kept arriving.
    public func sendersIgnoringUnsubscribe(accountId: Int64) async throws -> [String] {
        let attempts = try await fetchUnsubscribeAttempts(accountId: accountId)
        guard !attempts.isEmpty else { return [] }

        return try await dbWriter.read { db in
            var ignoring: [String] = []
            for attempt in attempts where attempt.succeeded {
                let latest = try Date.fetchOne(db, sql: """
                    SELECT MAX(date) FROM emailMetadata
                    WHERE accountId = ? AND LOWER(senderEmail) = ?
                    """,
                    arguments: [accountId, attempt.senderEmail]
                )
                if attempt.wasIgnored(latestMailDate: latest) {
                    ignoring.append(attempt.senderEmail)
                }
            }
            return ignoring
        }
    }
}

// MARK: - Golden Labels & Evaluation

extension AppDatabase {
    public func fetchGoldenLabels(accountId: Int64) async throws -> [GoldenLabel] {
        try await dbWriter.read { db in
            try GoldenLabel
                .filter(GoldenLabel.Columns.accountId == accountId)
                .order(GoldenLabel.Columns.labelledAt.desc)
                .fetchAll(db)
        }
    }

    public func saveGoldenLabel(_ label: GoldenLabel) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO goldenLabel
                        (accountId, senderEmail, expectedCategory, disposition, note, labelledAt)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(accountId, senderEmail) DO UPDATE SET
                        expectedCategory = excluded.expectedCategory,
                        disposition = excluded.disposition,
                        note = excluded.note,
                        labelledAt = excluded.labelledAt
                    """,
                arguments: [
                    label.accountId,
                    label.senderEmail.lowercased(),
                    label.expectedCategory.rawValue,
                    label.disposition.rawValue,
                    label.note,
                    label.labelledAt
                ]
            )
        }
    }

    public func deleteGoldenLabel(accountId: Int64, senderEmail: String) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: "DELETE FROM goldenLabel WHERE accountId = ? AND LOWER(senderEmail) = ?",
                arguments: [accountId, senderEmail.lowercased()]
            )
        }
    }

    /// Run the evaluation harness over every labelled sender's mail.
    ///
    /// Re-runs categorization rather than reading the stored decisions, so the report
    /// reflects the engine as it behaves NOW — otherwise a rule change would not show
    /// up until the whole mailbox was re-categorized.
    public func evaluate(
        accountId: Int64,
        engine: CategorizationEngine,
        rules: ActionRules
    ) async throws -> EvaluationReport {
        let labels = try await fetchGoldenLabels(accountId: accountId)
        guard !labels.isEmpty else {
            return CategorizationEvaluator(rules: rules)
                .evaluate(emails: [], results: [], labels: [], accountId: accountId)
        }

        let labelledSenders = Set(labels.map { $0.senderEmail.lowercased() })
        let all = try await fetchEmails(accountId: accountId, includeExecuted: true, limit: 50000)
        let relevant = all.filter { labelledSenders.contains($0.senderEmail.lowercased()) }

        let results = try await engine.categorize(emails: relevant)

        return CategorizationEvaluator(rules: rules).evaluate(
            emails: relevant,
            results: results,
            labels: labels,
            accountId: accountId
        )
    }

    /// Export the golden set so it can be committed as a repo fixture rather than
    /// living only in one machine's database.
    public func exportGoldenSet(accountId: Int64, accountEmail: String) async throws -> GoldenSetExport {
        let labels = try await fetchGoldenLabels(accountId: accountId)
        return GoldenSetExport(
            accountEmail: accountEmail,
            labels: labels.map {
                GoldenSetExport.ExportedLabel(
                    senderEmail: $0.senderEmail,
                    expectedCategory: $0.expectedCategory.rawValue,
                    disposition: $0.disposition.rawValue,
                    note: $0.note
                )
            }
        )
    }
}

// MARK: - Sender Verdict Cache

extension AppDatabase: SenderVerdictCaching {
    public func cachedVerdicts(
        accountId: Int64,
        senderEmails: [String],
        modelId: String,
        promptVersion: String
    ) async throws -> [String: SenderVerdict] {
        guard !senderEmails.isEmpty else { return [:] }
        let normalized = senderEmails.map { $0.lowercased() }

        return try await dbWriter.read { db in
            let placeholders = normalized.map { _ in "?" }.joined(separator: ",")
            var arguments: [DatabaseValueConvertible] = [accountId, modelId, promptVersion]
            arguments.append(contentsOf: normalized)

            let rows = try Row.fetchAll(db, sql: """
                SELECT senderEmail, category, mustKeep, isRealPerson, confidence, reason
                FROM senderVerdict
                WHERE accountId = ? AND modelId = ? AND promptVersion = ?
                  AND senderEmail IN (\(placeholders))
                """,
                arguments: StatementArguments(arguments)
            )

            var verdicts: [String: SenderVerdict] = [:]
            for row in rows {
                guard let raw: String = row["category"],
                      let category = EmailCategory(rawValue: raw) else { continue }
                let sender: String = row["senderEmail"]
                verdicts[sender.lowercased()] = SenderVerdict(
                    senderEmail: sender,
                    category: category,
                    mustKeep: row["mustKeep"],
                    isRealPerson: row["isRealPerson"],
                    confidence: row["confidence"],
                    reason: row["reason"]
                )
            }
            return verdicts
        }
    }

    public func storeVerdicts(
        _ verdicts: [SenderVerdict],
        accountId: Int64,
        modelId: String,
        promptVersion: String
    ) async throws {
        guard !verdicts.isEmpty else { return }
        try await dbWriter.write { db in
            for verdict in verdicts {
                try db.execute(
                    sql: """
                        INSERT INTO senderVerdict
                            (accountId, senderEmail, modelId, promptVersion, category,
                             mustKeep, isRealPerson, confidence, reason, createdAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(accountId, senderEmail, modelId, promptVersion)
                        DO UPDATE SET
                            category = excluded.category,
                            mustKeep = excluded.mustKeep,
                            isRealPerson = excluded.isRealPerson,
                            confidence = excluded.confidence,
                            reason = excluded.reason,
                            createdAt = excluded.createdAt
                        """,
                    arguments: [
                        accountId,
                        verdict.senderEmail.lowercased(),
                        modelId,
                        promptVersion,
                        verdict.category.rawValue,
                        verdict.mustKeep,
                        verdict.isRealPerson,
                        verdict.confidence,
                        verdict.reason,
                        Date()
                    ]
                )
            }
        }
    }

    /// Recent subject lines from a sender, for building a classification request.
    public func sampleSubjects(
        accountId: Int64,
        senderEmail: String,
        limit: Int = 5
    ) async throws -> [String] {
        try await dbWriter.read { db in
            try String.fetchAll(db, sql: """
                SELECT subject FROM emailMetadata
                WHERE accountId = ? AND LOWER(senderEmail) = ?
                ORDER BY date DESC
                LIMIT ?
                """,
                arguments: [accountId, senderEmail.lowercased(), limit]
            )
        }
    }

    /// How many senders currently have a cached verdict for this model and prompt.
    public func cachedVerdictCount(
        accountId: Int64,
        modelId: String,
        promptVersion: String
    ) async throws -> Int {
        try await dbWriter.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM senderVerdict
                WHERE accountId = ? AND modelId = ? AND promptVersion = ?
                """,
                arguments: [accountId, modelId, promptVersion]
            ) ?? 0
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
                        SET actionTaken = NULL, actionDate = NULL,
                            actionExecutedAt = NULL, updatedAt = ?
                        WHERE accountId = ? AND messageId IN (\(placeholders))
                        """,
                    arguments: arguments
                )
            }
        }
    }

    /// Record that an action was actually carried out against the provider.
    ///
    /// Distinct from ``markEmailsActioned(messageIds:accountId:action:)``, which only
    /// records the user's intent. Executed mail leaves the working views but is kept
    /// in the database so the action remains undoable.
    public func markEmailsExecuted(
        messageIds: [String],
        accountId: Int64,
        action: EmailAction,
        executedAt: Date = Date()
    ) async throws {
        guard !messageIds.isEmpty else { return }
        let placeholders = messageIds.map { _ in "?" }.joined(separator: ",")

        try await dbWriter.write { db in
            var arguments: StatementArguments = [
                action.rawValue, executedAt, executedAt, executedAt, accountId
            ]
            for id in messageIds { arguments += [id] }
            try db.execute(
                sql: """
                    UPDATE emailMetadata
                    SET actionTaken = ?, actionDate = ?, actionExecutedAt = ?, updatedAt = ?
                    WHERE accountId = ? AND messageId IN (\(placeholders))
                    """,
                arguments: arguments
            )
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

    /// Action history for one account, newest first — backs the History tab.
    public func fetchActionHistory(accountId: Int64, limit: Int = 200) async throws -> [ActionLog] {
        try await dbWriter.read { db in
            try ActionLog
                .filter(ActionLog.Columns.accountId == accountId)
                .order(ActionLog.Columns.executedAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func fetchAction(id: Int64) async throws -> ActionLog? {
        try await dbWriter.read { db in
            try ActionLog.filter(ActionLog.Columns.id == id).fetchOne(db)
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
