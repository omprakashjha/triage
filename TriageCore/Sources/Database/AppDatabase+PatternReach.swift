import Foundation
import GRDB

// MARK: - Scope feedback for corrections

public extension AppDatabase {
    /// How many of a sender's emails a subject pattern would match, and how many they have.
    ///
    /// Exists to make the generalisation tradeoff visible AT THE MOMENT of deciding. A pattern
    /// is a rule for mail that has not arrived yet, and the difference between a good one and a
    /// useless one is invisible while typing: "Jaarafrekening van waterbedrijf Vitens" matches
    /// the one email it came from, while "jaarafrekening" matches every annual statement the
    /// utility will ever send. The model made exactly this mistake last night, returning whole
    /// subject lines as "patterns" that matched one message each — there is no reason to make
    /// the user guess where the model could not.
    ///
    /// Returned as a pair so the caller can render "23 of 54" rather than a bare number, which
    /// is what actually communicates whether a pattern generalises.
    func subjectPatternReach(
        accountId: Int64,
        senderEmail: String,
        subjectPattern: String
    ) async throws -> (matching: Int, total: Int) {
        let sender = senderEmail.lowercased()
        let pattern = subjectPattern
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return try await dbWriter.read { db in
            let total = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM emailMetadata
                    WHERE accountId = ? AND LOWER(senderEmail) = ?
                    """,
                arguments: [accountId, sender]
            ) ?? 0

            // An empty pattern means the whole sender, which is what a correction with no
            // pattern does — reporting 0 there would misdescribe it.
            guard !pattern.isEmpty else { return (total, total) }

            let matching = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM emailMetadata
                    WHERE accountId = ? AND LOWER(senderEmail) = ?
                      AND INSTR(LOWER(subject), ?) > 0
                    """,
                arguments: [accountId, sender, pattern]
            ) ?? 0
            return (matching, total)
        }
    }
}
