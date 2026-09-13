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

        // Counted in Swift rather than with SQL's INSTR, so it uses the SAME normalization as the
        // matching that will actually decide the mail. An INSTR against the raw subject reported a
        // reach the correction could not deliver — it would say "matches 12" and then move none of
        // them, because a generated stem has had its punctuation replaced by spaces. A sender's
        // mail is at most a few hundred rows, so the cost of being correct here is nil.
        let subjects: [String] = try await dbWriter.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT subject FROM emailMetadata
                    WHERE accountId = ? AND LOWER(senderEmail) = ?
                    """,
                arguments: [accountId, sender]
            )
        }

        let total = subjects.count
        let pattern = subjectPattern.trimmingCharacters(in: .whitespacesAndNewlines)

        // An empty pattern means the whole sender, which is what a correction with no pattern
        // does — reporting 0 there would misdescribe it.
        guard !pattern.isEmpty else { return (total, total) }

        let matching = subjects.filter { SubjectStem.pattern(pattern, matches: $0) }.count
        return (matching, total)
    }
}
