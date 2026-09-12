import Foundation
import GRDB

// MARK: - User corrections

public extension AppDatabase {
    /// Record a correction, replacing any previous one for the same scope.
    ///
    /// Invalidating the sender's cached model verdict in the SAME transaction is the part
    /// that matters. Without it the correction would be silently re-fought on the next
    /// scan: the cache would hand back the stale wrong verdict, the user would correct it
    /// again, and the app would look like it was ignoring them.
    func saveCorrection(_ correction: UserCorrection) async throws {
        try await dbWriter.write { db in
            // The unique key is (account, sender, pattern), and SQLite treats NULL as
            // distinct from NULL in unique constraints — so a whole-sender correction
            // cannot be upserted by the constraint alone and is cleared explicitly.
            if correction.subjectPattern == nil {
                try UserCorrection
                    .filter(UserCorrection.Columns.accountId == correction.accountId)
                    .filter(UserCorrection.Columns.senderEmail == correction.senderEmail)
                    .filter(UserCorrection.Columns.subjectPattern == nil)
                    .deleteAll(db)
            }

            var toSave = correction
            try toSave.upsert(db)

            // Verdicts are stored via raw SQL rather than a record type, so they are
            // cleared the same way.
            try db.execute(
                sql: "DELETE FROM senderVerdict WHERE accountId = ? AND senderEmail = ?",
                arguments: [correction.accountId, correction.senderEmail]
            )
        }
    }

    func corrections(accountId: Int64) async throws -> [UserCorrection] {
        try await dbWriter.read { db in
            try UserCorrection
                .filter(UserCorrection.Columns.accountId == accountId)
                .order(UserCorrection.Columns.correctedAt.desc)
                .fetchAll(db)
        }
    }

    func deleteCorrection(id: Int64) async throws {
        _ = try await dbWriter.write { db in
            try UserCorrection.deleteOne(db, key: id)
        }
    }

    /// Corrections rendered as prompt examples, newest first.
    ///
    /// Capped deliberately. The point is to teach the model this mailbox's shape, which a
    /// few dozen examples do; pasting hundreds would crowd out the senders being asked
    /// about and cost tokens on every batch.
    func correctionExamples(accountId: Int64, limit: Int = 40) async throws -> [CorrectionExample] {
        let stored = try await corrections(accountId: accountId)
        return stored.prefix(limit).map {
            CorrectionExample(
                senderEmail: $0.senderEmail,
                subjectPattern: $0.subjectPattern,
                category: $0.category,
                mustKeep: $0.mustKeep
            )
        }
    }

    /// Turn corrections into golden labels, so accuracy becomes measurable from ordinary
    /// use instead of requiring a separate labelling chore.
    ///
    /// Promotes EVERY correction, subject scope included. This originally promoted only
    /// whole-sender corrections, on the reasoning that the golden set was keyed by sender and
    /// a partial representation would poison the metric. The reasoning was sound and the
    /// conclusion was wrong: on real use 26 of 29 corrections were subject-scoped, so the
    /// rule discarded 90% of the available ground truth and produced 3 labels — from which no
    /// precision figure means anything. The right fix was to give labels the same scope
    /// corrections have, not to throw the corrections away.
    func promoteCorrectionsToGoldenLabels(accountId: Int64) async throws -> Int {
        let all = try await corrections(accountId: accountId)

        var written = 0
        for correction in all {
            try await saveGoldenLabel(
                GoldenLabel(
                    accountId: accountId,
                    senderEmail: correction.senderEmail,
                    subjectPattern: correction.subjectPattern,
                    expectedCategory: correction.category,
                    disposition: correction.mustKeep ? .mustKeep : .disposable,
                    note: "From a user correction"
                )
            )
            written += 1
        }
        return written
    }
}

// MARK: - Sender heterogeneity

public extension AppDatabase {
    /// Every stored message from one sender.
    ///
    /// Used to re-categorize just that sender after a correction. Scoping the pass to the
    /// affected sender is what makes a correction feel immediate — waiting through a full
    /// mailbox pass to see your own instruction applied is how a feature like this stops
    /// being used.
    func emails(accountId: Int64, senderEmail: String) async throws -> [EmailMetadata] {
        try await dbWriter.read { db in
            try EmailMetadata
                .filter(Column("accountId") == accountId)
                .filter(Column("senderEmail").lowercased == senderEmail.lowercased())
                .fetchAll(db)
        }
    }
}

public extension AppDatabase {
    /// Body previews for a sender, for the model to read.
    ///
    /// Separate from `sampleSubjects` so the caller must opt in explicitly: this returns
    /// message CONTENT, and the decision to send it off the machine belongs to the user,
    /// not to a convenient default.
    func sampleSnippets(accountId: Int64, senderEmail: String, limit: Int = 3) async throws -> [String] {
        try await dbWriter.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT snippet FROM emailMetadata
                    WHERE accountId = ? AND LOWER(senderEmail) = ?
                      AND snippet IS NOT NULL AND LENGTH(snippet) > 20
                    ORDER BY date DESC LIMIT ?
                    """,
                arguments: [accountId, senderEmail.lowercased(), limit]
            )
        }
    }

    /// How the provider filed a sender's mail, counted per label.
    ///
    /// More than one non-zero entry is the clearest available evidence that a sender is
    /// mixed, and mixed senders are the ones a single verdict cannot describe.
    func providerLabelCounts(accountId: Int64, senderEmail: String) async throws -> [String: Int] {
        let rows = try await dbWriter.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT labels FROM emailMetadata
                    WHERE accountId = ? AND LOWER(senderEmail) = ? AND labels IS NOT NULL
                    """,
                arguments: [accountId, senderEmail.lowercased()]
            )
        }

        var counts: [String: Int] = [:]
        let decoder = JSONDecoder()
        for row in rows {
            guard let json: String = row["labels"],
                  let labels = try? decoder.decode([String].self, from: Data(json.utf8))
            else { continue }
            for label in labels {
                if let category = ProviderCategory(gmailLabel: label) {
                    counts[category.displayName, default: 0] += 1
                }
            }
        }
        return counts
    }

    /// Whether the user has ever sent mail in one of this sender's threads.
    func userHasReplied(accountId: Int64, senderEmail: String) async throws -> Bool {
        try await dbWriter.read { db in
            let count = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM emailMetadata
                    WHERE accountId = ? AND threadId IN (
                        SELECT threadId FROM emailMetadata
                        WHERE accountId = ? AND LOWER(senderEmail) = ?
                    )
                    AND labels LIKE '%SENT%'
                    """,
                arguments: [accountId, accountId, senderEmail.lowercased()]
            )
            return (count ?? 0) > 0
        }
    }
}
