import Foundation
import GRDB

// MARK: - Reviewing individual messages

public extension AppDatabase {
    /// Mail still awaiting a decision, newest first, with the model's reasoning attached.
    func emailsAwaitingReview(accountId: Int64, limit: Int = 500) async throws -> [EmailMetadata] {
        try await dbWriter.read { db in
            try EmailMetadata
                .filter(Column("accountId") == accountId)
                .filter(Column("safetyTier") == SafetyTier.review.rawValue)
                .order(Column("senderEmail"), Column("date").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Specific messages by id, for re-running the engine over only what changed.
    func emails(accountId: Int64, messageIds: [String]) async throws -> [EmailMetadata] {
        guard !messageIds.isEmpty else { return [] }
        return try await dbWriter.read { db in
            var all: [EmailMetadata] = []
            // Chunked for the same reason the writer is: a bulk accept can cover the whole
            // review queue and SQLite caps bound parameters.
            for chunk in messageIds.chunked(into: 400) {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                var arguments: [DatabaseValueConvertible] = [accountId]
                arguments.append(contentsOf: chunk)
                all += try EmailMetadata.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM emailMetadata
                        WHERE accountId = ? AND messageId IN (\(placeholders))
                        """,
                    arguments: StatementArguments(arguments)
                )
            }
            return all
        }
    }

    /// Record a decision for specific messages.
    ///
    /// Takes a LIST because the decision that actually needs making is a bulk one. Once the
    /// model has read every message individually, the user is not adjudicating 103 separate
    /// questions — they are accepting or rejecting a body of work, with exceptions. Making
    /// them click 103 times to express one judgement would be the same mistake as presenting
    /// a review queue instead of a ranked list of decisions.
    ///
    /// Passing nil clears the decision and returns the mail to the classifier.
    func recordDisposalDecision(
        _ decision: DisposalDecision?,
        messageIds: [String],
        accountId: Int64
    ) async throws {
        guard !messageIds.isEmpty else { return }
        try await dbWriter.write { db in
            // Chunked because SQLite has a hard limit on bound parameters and a bulk accept
            // can legitimately cover the whole review queue.
            for chunk in messageIds.chunked(into: 400) {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                var arguments: [DatabaseValueConvertible?] = [decision?.rawValue, accountId]
                arguments.append(contentsOf: chunk.map { $0 })

                try db.execute(
                    sql: """
                        UPDATE emailMetadata
                        SET userDisposalDecision = ?,
                            updatedAt = datetime('now')
                        WHERE accountId = ? AND messageId IN (\(placeholders))
                        """,
                    arguments: StatementArguments(arguments)
                )
            }
        }
    }

    /// How many messages carry an explicit decision, for reporting progress.
    func disposalDecisionCounts(accountId: Int64) async throws -> (dispose: Int, keep: Int) {
        try await dbWriter.read { db in
            let dispose = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM emailMetadata
                    WHERE accountId = ? AND userDisposalDecision = ?
                    """,
                arguments: [accountId, DisposalDecision.dispose.rawValue]
            ) ?? 0
            let keep = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM emailMetadata
                    WHERE accountId = ? AND userDisposalDecision = ?
                    """,
                arguments: [accountId, DisposalDecision.keep.rawValue]
            ) ?? 0
            return (dispose, keep)
        }
    }
}
