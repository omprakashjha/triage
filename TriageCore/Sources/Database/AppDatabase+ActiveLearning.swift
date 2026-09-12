import Foundation
import GRDB

// MARK: - Active learning: which decisions buy the most

public extension AppDatabase {
    /// Senders worth asking about, highest leverage first.
    ///
    /// Ranked by how many messages ONE decision would resolve, which is the whole point:
    /// on a real mailbox six senders held 58% of a 232-email review queue, so ranking turns
    /// scrolling into a short interview.
    ///
    /// Senders the user has already ruled on are excluded — asking again would waste the only
    /// resource this feature spends, which is the user's attention. Protected mail is excluded
    /// too, since a contact is already settled.
    func triageCandidates(
        accountId: Int64,
        modelId: String,
        promptVersion: String,
        limit: Int = 25
    ) async throws -> [TriageCandidate] {
        let rows = try await dbWriter.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        LOWER(e.senderEmail) AS senderEmail,
                        MAX(e.sender)        AS displayName,
                        SUM(CASE WHEN e.safetyTier = 'review' THEN 1 ELSE 0 END) AS pendingCount,
                        COUNT(*)             AS totalCount,
                        MAX(e.category)      AS currentCategory,
                        MAX(e.safetyTier)    AS currentTier,
                        MAX(e.categoryReason) AS currentReason,
                        MAX(CASE WHEN e.hasListUnsubscribe THEN 1 ELSE 0 END) AS hasUnsubscribe,
                        v.category           AS modelCategory,
                        v.mustKeep           AS modelMustKeep,
                        v.reason             AS modelReason,
                        v.isUnsure           AS modelWasUnsure
                    FROM emailMetadata e
                    LEFT JOIN senderVerdict v
                        ON v.accountId = e.accountId
                       AND v.senderEmail = LOWER(e.senderEmail)
                       AND v.modelId = ?
                       AND v.promptVersion = ?
                    WHERE e.accountId = ?
                      AND e.safetyTier IS NOT 'protected_'
                      -- Excluded by EITHER route the user can rule on a sender.
                      --
                      -- Originally only corrections were checked, which made confirming a
                      -- sender do nothing visible: a confirmation deliberately writes no
                      -- correction, so the candidate came straight back at the top of the
                      -- queue and the same decision reappeared indefinitely. The label is
                      -- what records "the user has ruled on this", whichever button produced
                      -- it, so the label table is what the exclusion must consult.
                      AND NOT EXISTS (
                            SELECT 1 FROM userCorrection c
                            WHERE c.accountId = e.accountId
                              AND c.senderEmail = LOWER(e.senderEmail)
                          )
                      AND NOT EXISTS (
                            SELECT 1 FROM goldenLabel g
                            WHERE g.accountId = e.accountId
                              AND g.senderEmail = LOWER(e.senderEmail)
                          )
                    GROUP BY LOWER(e.senderEmail)
                    HAVING pendingCount > 0
                    ORDER BY pendingCount DESC, totalCount DESC
                    LIMIT ?
                    """,
                arguments: [modelId, promptVersion, accountId, limit]
            )
        }

        var candidates: [TriageCandidate] = []
        for row in rows {
            let sender: String = row["senderEmail"]
            candidates.append(
                TriageCandidate(
                    senderEmail: sender,
                    displayName: row["displayName"] ?? sender,
                    pendingCount: row["pendingCount"] ?? 0,
                    totalCount: row["totalCount"] ?? 0,
                    currentCategory: EmailCategory(rawValue: row["currentCategory"] ?? ""),
                    currentTier: SafetyTier(rawValue: row["currentTier"] ?? ""),
                    currentReason: row["currentReason"],
                    modelCategory: EmailCategory(rawValue: row["modelCategory"] ?? ""),
                    modelMustKeep: row["modelMustKeep"],
                    modelReason: row["modelReason"],
                    modelWasUnsure: row["modelWasUnsure"] ?? false,
                    sampleSubjects: try await sampleSubjects(
                        accountId: accountId, senderEmail: sender
                    ),
                    providerLabelCounts: try await providerLabelCounts(
                        accountId: accountId, senderEmail: sender
                    ),
                    hasUnsubscribe: (row["hasUnsubscribe"] ?? 0) == 1
                )
            )
        }
        return candidates
    }

    /// Record that the user agrees with what the app currently says about a sender.
    ///
    /// Writes a LABEL ONLY — no correction. That distinction is the point. A correction changes
    /// the pipeline's behaviour and therefore cannot measure it; a confirmation changes nothing
    /// and is the only kind of ground truth this app can collect that means something. It is
    /// what makes the confirm-to-correct ratio an accuracy figure rather than a tautology.
    func confirmVerdict(
        accountId: Int64,
        senderEmail: String,
        category: EmailCategory,
        mustKeep: Bool
    ) async throws {
        try await saveGoldenLabel(
            GoldenLabel(
                accountId: accountId,
                senderEmail: senderEmail,
                expectedCategory: category,
                disposition: mustKeep ? .mustKeep : .disposable,
                note: LabelProvenance.confirmation.note
            )
        )
    }

    /// How often the user endorsed the app's own verdict, over senders they were asked about.
    ///
    /// Only confirmations and the corrections that overturned them are counted, so this
    /// excludes the circular labels promoted in bulk from pre-existing corrections.
    func agreementRate(accountId: Int64) async throws -> (confirmed: Int, overturned: Int) {
        try await dbWriter.read { db in
            let confirmed = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM goldenLabel WHERE accountId = ? AND note = ?",
                arguments: [accountId, LabelProvenance.confirmation.note]
            ) ?? 0

            // A correction made from the decision queue overturned a verdict the user was
            // shown. Distinguished from bulk-promoted ones by there being a label for the
            // same sender that came from a correction rather than a confirmation.
            let overturned = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(DISTINCT c.senderEmail) FROM userCorrection c
                    WHERE c.accountId = ?
                      AND EXISTS (
                            SELECT 1 FROM goldenLabel g
                            WHERE g.accountId = c.accountId
                              AND g.senderEmail = c.senderEmail
                              AND g.note = ?
                          )
                    """,
                arguments: [accountId, LabelProvenance.correction.note]
            ) ?? 0

            return (confirmed, overturned)
        }
    }
}
