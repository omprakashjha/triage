import Foundation

/// Applies the user's own corrections on top of whatever engine sits beneath.
///
/// A wrapper rather than a branch inside the rule engine, for two reasons. It composes —
/// corrections outrank the rules AND the model without either needing to know corrections
/// exist. And it cannot be bypassed: every path that categorizes mail goes through the
/// outermost engine, so there is no route that consults the rules while forgetting what
/// the user said.
///
/// Precedence is total. A correction is the only signal in the system that is not a guess,
/// so nothing below it may override it — including a model verdict that disagrees, and
/// including the rules' own strong evidence.
public final class CorrectingEngine: CategorizationEngine {
    private let base: CategorizationEngine
    /// Corrections grouped by sender, most specific first so a subject-scoped correction
    /// beats a whole-sender one.
    private let bySender: [String: [UserCorrection]]

    public init(base: CategorizationEngine, corrections: [UserCorrection]) {
        self.base = base
        self.bySender = Dictionary(grouping: corrections) { $0.senderEmail }
            .mapValues { $0.sorted { $0.specificity > $1.specificity } }
    }

    public func categorize(emails: [EmailMetadata]) async throws -> [CategorizationResult] {
        // Mail the user has already ruled on does not need classifying, so it is withheld
        // from the base engine entirely. On a mailbox with many corrections that is also
        // the cheapest possible outcome: no rules run and, more importantly, no model call
        // is made for a sender whose answer is already known.
        var corrected: [String: CategorizationResult] = [:]
        var remaining: [EmailMetadata] = []

        for email in emails {
            if let correction = matchingCorrection(for: email) {
                corrected[email.messageId] = Self.result(for: email, correction: correction)
            } else {
                remaining.append(email)
            }
        }

        let baseResults = remaining.isEmpty ? [] : try await base.categorize(emails: remaining)
        var byId = Dictionary(baseResults.map { ($0.messageId, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, result) in corrected {
            byId[id] = result
        }

        return emails.compactMap { byId[$0.messageId] }
    }

    func matchingCorrection(for email: EmailMetadata) -> UserCorrection? {
        guard let candidates = bySender[email.senderEmail.lowercased()] else { return nil }
        return candidates.first {
            $0.matches(senderEmail: email.senderEmail, subject: email.subject)
        }
    }

    static func result(for email: EmailMetadata, correction: UserCorrection) -> CategorizationResult {
        let scope = correction.subjectPattern == nil
            ? "this sender"
            : "subjects containing \"\(correction.subjectPattern!)\""

        return CategorizationResult(
            messageId: email.messageId,
            category: correction.category,
            safetyTier: correction.impliedTier,
            // Not a probability. The user is not estimating.
            confidence: 1.0,
            reason: "You set \(scope) to \(correction.category.displayName)",
            // Strong, so the invariant permits auto-action. A correction is the one source
            // allowed to authorise deletion alone: the corroboration requirement exists to
            // stop a fallible CLASSIFIER acting unilaterally, and the user is not one of
            // those — refusing to honour an explicit instruction is its own failure.
            evidence: .strong
        )
    }
}
