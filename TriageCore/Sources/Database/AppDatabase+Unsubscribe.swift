import Foundation
import GRDB

// MARK: - Unsubscribe candidates

public extension AppDatabase {

    /// Senders worth unsubscribing from, ranked by the mail they will stop arriving.
    ///
    /// Only senders that actually advertised an unsubscribe header are returned: without one there
    /// is nothing to act on, and listing them would offer the user a button that cannot work.
    ///
    /// The cadence is measured over the observed span rather than assumed. A sender seen once has no
    /// span to divide by, so it is credited with its single message per year rather than an infinite
    /// rate — that keeps a one-off from outranking a genuine weekly newsletter.
    func unsubscribeCandidates(
        accountId: Int64,
        now: Date = Date(),
        limit: Int = 100
    ) async throws -> [UnsubscribeCandidate] {
        // Read the model's own opinion per sender. Keyed by sender so the newest verdict wins, which
        // matters because re-categorization can leave several verdicts for one sender.
        let verdicts: [String: (category: String, keepSubjects: String?)] =
            try await dbWriter.read { db in
                var map: [String: (String, String?)] = [:]
                let rows = try Row.fetchAll(db, sql: """
                    SELECT senderEmail, category, keepSubjects
                    FROM senderVerdict
                    WHERE accountId = ?
                    ORDER BY id ASC
                    """, arguments: [accountId])
                for row in rows {
                    let sender: String = row["senderEmail"] ?? ""
                    map[sender.lowercased()] = (row["category"] ?? "", row["keepSubjects"])
                }
                return map
            }

        let attempted: Set<String> = try await dbWriter.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT LOWER(senderEmail) FROM unsubscribeAttempt WHERE accountId = ?
                """, arguments: [accountId]))
        }

        let rows: [Row] = try await dbWriter.read { db in
            try Row.fetchAll(db, sql: """
                SELECT
                    LOWER(senderEmail)                                   AS senderEmail,
                    MIN(sender)                                          AS displayName,
                    COUNT(*)                                             AS storedVolume,
                    SUM(COALESCE(supportsOneClickUnsubscribe, 0))         AS oneClickCount,
                    SUM(CASE WHEN safetyTier = 'protected_' THEN 1 ELSE 0 END) AS mustKeepCount,
                    MIN(date)                                            AS firstSeen,
                    MAX(date)                                            AS lastSeen
                FROM emailMetadata
                WHERE accountId = ?
                  AND hasListUnsubscribe = 1
                  AND actionExecutedAt IS NULL
                GROUP BY LOWER(senderEmail)
                LIMIT ?
                """, arguments: [accountId, limit])
        }

        let candidates: [UnsubscribeCandidate] = rows.compactMap { row in
            let sender: String = row["senderEmail"] ?? ""
            guard !sender.isEmpty else { return nil }
            let stored: Int = row["storedVolume"] ?? 0
            let firstSeen: Date = row["firstSeen"] ?? Date()
            let lastSeen: Date = row["lastSeen"] ?? firstSeen

            // Observed cadence, annualised over the window from first sight UNTIL NOW.
            //
            // Measuring only firstSeen..lastSeen was wrong and a test caught it: a sender with 30
            // messages packed into one month a year ago projected to 365 a year and outranked a live
            // sender sending 8 a month. Density while active is not the same question as how much
            // mail is still coming. Running the window to the present dilutes a sender that stopped,
            // which is the honest answer and makes dormancy a refinement rather than the only guard.
            //
            // Floored at a QUARTER, not a month. A 30-day floor let a sender first seen three weeks
            // ago project from two messages to 24 a year and outrank a sender with 65 — measured on
            // the real mailbox. Extrapolating an annual rate from a handful of messages in a short
            // window is not a measurement, and the floor is what stops it.
            let spanDays = max(now.timeIntervalSince(firstSeen) / 86_400, 90.0)
            let perYear = Double(stored) * (365.0 / spanDays)

            let verdict = verdicts[sender]
            let keepSubjects: [String] = {
                guard let raw = verdict?.keepSubjects,
                      let data = raw.data(using: .utf8),
                      let list = try? JSONDecoder().decode([String].self, from: data)
                else { return [] }
                return list.filter { !$0.isEmpty }
            }()

            return UnsubscribeCandidate(
                senderEmail: sender,
                displayName: row["displayName"] ?? sender,
                storedVolume: stored,
                projectedYearlyVolume: perYear,
                oneClickCount: row["oneClickCount"] ?? 0,
                mustKeepCount: row["mustKeepCount"] ?? 0,
                modelCategory: verdict.flatMap { EmailCategory(rawValue: $0.category) },
                modelKeepSubjects: keepSubjects,
                firstSeen: firstSeen,
                lastSeen: lastSeen,
                alreadyAttempted: attempted.contains(sender)
            )
        }

        // Sorted by what the user gains. Actionable recommendations come first, because a rate alone
        // cannot separate "was busy, is now silent" from "busy now": a sender that fired thirty
        // messages and stopped a year ago still carries a high lifetime rate and would otherwise head
        // a list of things worth doing, none of which it is. Within each group, mail prevented per
        // year decides. Senders already attempted sink to the bottom rather than disappearing,
        // because an attempt that was ignored is itself worth seeing.
        func rank(_ c: UnsubscribeCandidate) -> Int {
            switch c.recommendation(asOf: now) {
            case .unsubscribe: return 0
            case .unsubscribeWithCollateral: return 1
            case .dormant: return 2
            case .notWorthIt: return 3
            }
        }
        return candidates.sorted { a, b in
            if a.alreadyAttempted != b.alreadyAttempted { return !a.alreadyAttempted }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return a.projectedYearlyVolume > b.projectedYearlyVolume
        }
    }
}
