import Foundation

/// Rules first, model only on what the rules could not resolve.
///
/// Two design decisions carry most of the value:
///
/// 1. The model is asked about SENDERS, not messages, and only about the ambiguous
///    residue. Deterministic signals (a `List-Unsubscribe` header, a known marketing
///    platform like `list-manage.com`) are facts — asking a model to re-derive them
///    would be slower, costlier and less reliable.
///
/// 2. A model verdict can only ever move mail toward SAFETY. The final tier is the
///    stricter of the rule tier and the model tier, so a hallucinated verdict costs the
///    user one unnecessary manual review, never a deleted receipt. This is enforced
///    here in code rather than requested in the prompt, because a prompt is not a
///    guarantee.
/// What one AI categorization pass actually did.
///
/// Exists because the engine's effect was being inferred from stored reasons and got it
/// wrong: 22 verdicts were cached while zero emails carried AI attribution, and no
/// amount of reading the code settled why. Counting the steps is cheaper than guessing.
public struct AIRunDiagnostics: Sendable {
    public var sendersConsidered = 0
    public var verdictsFromCache = 0
    public var batchesRequested = 0
    public var verdictsReturned = 0
    public var mergesApplied = 0
    public var failure: String?

    public var summary: String {
        if let failure {
            return "AI pass FAILED after \(verdictsReturned) verdicts: \(failure)"
        }
        return "AI: \(sendersConsidered) ambiguous senders, "
            + "\(verdictsFromCache) cached + \(verdictsReturned) fetched in \(batchesRequested) call(s), "
            + "\(mergesApplied) emails merged."
    }
}

public final class AICategorizationEngine: CategorizationEngine {

    /// Rule results at or above this confidence are accepted as-is and never sent to
    /// the model.
    public static let ruleConfidenceCeiling = 0.7

    /// Senders per model call.
    public static let batchSize = 50

    private let rules: RuleBasedEngine
    private let transport: LLMTransport
    private let cache: SenderVerdictCaching
    private let accountId: Int64
    private let sampleSubjects: (String) async -> [String]
    /// Reports what the pass did. Called once per `categorize`, success or failure.
    private let onDiagnostics: (@Sendable (AIRunDiagnostics) -> Void)?

    public init(
        rules: RuleBasedEngine,
        transport: LLMTransport,
        cache: SenderVerdictCaching,
        accountId: Int64,
        sampleSubjects: @escaping (String) async -> [String] = { _ in [] },
        onDiagnostics: (@Sendable (AIRunDiagnostics) -> Void)? = nil
    ) {
        self.rules = rules
        self.transport = transport
        self.cache = cache
        self.accountId = accountId
        self.sampleSubjects = sampleSubjects
        self.onDiagnostics = onDiagnostics
    }

    public func categorize(emails: [EmailMetadata]) async throws -> [CategorizationResult] {
        var diagnostics = AIRunDiagnostics()
        do {
            let results = try await runCategorize(emails: emails, diagnostics: &diagnostics)
            onDiagnostics?(diagnostics)
            return results
        } catch {
            // Report BEFORE rethrowing. Without this a mid-pass failure looks identical
            // to the AI having no effect, which is exactly what happened.
            diagnostics.failure = error.localizedDescription
            onDiagnostics?(diagnostics)
            throw error
        }
    }

    private func runCategorize(
        emails: [EmailMetadata],
        diagnostics: inout AIRunDiagnostics
    ) async throws -> [CategorizationResult] {
        let ruleResults = try await rules.categorize(emails: emails)
        guard !emails.isEmpty else { return ruleResults }

        var resultsById = Dictionary(
            ruleResults.map { ($0.messageId, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Which senders actually need a model opinion.
        let ambiguousSenders = Self.sendersNeedingClassification(
            emails: emails,
            ruleResults: resultsById
        )
        diagnostics.sendersConsidered = ambiguousSenders.count
        guard !ambiguousSenders.isEmpty else { return ruleResults }

        // Cached verdicts cost nothing — a rescan should not re-pay for a sender
        // already judged by this model and prompt.
        var verdicts = try await cache.cachedVerdicts(
            accountId: accountId,
            senderEmails: ambiguousSenders,
            modelId: transport.modelId,
            promptVersion: transport.promptVersion
        )
        diagnostics.verdictsFromCache = verdicts.count

        let uncached = ambiguousSenders.filter { verdicts[$0] == nil }
        if !uncached.isEmpty {
            let requests = await buildRequests(for: uncached, emails: emails)
            for batch in requests.chunked(into: Self.batchSize) {
                diagnostics.batchesRequested += 1
                let fresh = try await transport.classify(senders: batch)
                diagnostics.verdictsReturned += fresh.count
                try await cache.storeVerdicts(
                    fresh,
                    accountId: accountId,
                    modelId: transport.modelId,
                    promptVersion: transport.promptVersion
                )
                for verdict in fresh {
                    verdicts[verdict.senderEmail.lowercased()] = verdict
                }
            }
        }

        // Merge, narrowing only.
        for email in emails {
            guard let ruleResult = resultsById[email.messageId] else { continue }
            guard let verdict = verdicts[email.senderEmail.lowercased()] else { continue }
            resultsById[email.messageId] = Self.merge(
                rule: ruleResult,
                verdict: verdict,
                // Per-MESSAGE, which is what lets a mixed sender be split correctly:
                // info@email.ns.nl is 46 promotional and 58 receipts, and one sender-level
                // verdict cannot be right for both. The provider labelled each message
                // individually, so corroboration is decided message by message.
                providerCategory: email.providerCategory
            )
            diagnostics.mergesApplied += 1
        }

        // Preserve input order.
        return emails.compactMap { resultsById[$0.messageId] }
    }

    // MARK: - Selection

    /// Senders whose mail the rules could not resolve on STRONG evidence.
    ///
    /// Deliberately not a confidence threshold any more. Confidence is a hand-assigned
    /// literal, so a baseless 0.85 used to outrank the model and keep whole categories of
    /// mail away from the only component that could read them — measurably so on a
    /// non-English mailbox, where 80% of decisions came from heuristics.
    ///
    /// Protected mail is still excluded: a contact is already settled, and no verdict
    /// could improve on that.
    static func sendersNeedingClassification(
        emails: [EmailMetadata],
        ruleResults: [String: CategorizationResult]
    ) -> [String] {
        var senders: Set<String> = []
        for email in emails {
            guard let result = ruleResults[email.messageId] else { continue }
            if result.safetyTier == .protected_ { continue }
            if !result.evidence.canAutoAction {
                senders.insert(email.senderEmail.lowercased())
            }
        }
        return senders.sorted()
    }

    private func buildRequests(
        for senders: [String],
        emails: [EmailMetadata]
    ) async -> [SenderClassificationRequest] {
        var grouped: [String: [EmailMetadata]] = [:]
        for email in emails {
            let key = email.senderEmail.lowercased()
            guard senders.contains(key) else { continue }
            grouped[key, default: []].append(email)
        }

        var requests: [SenderClassificationRequest] = []
        for sender in senders {
            let senderEmails = (grouped[sender] ?? []).sorted { $0.date > $1.date }
            var subjects = senderEmails.prefix(5).map(\.subject)
            if subjects.isEmpty {
                subjects = await sampleSubjects(sender)
            }

            let dates = senderEmails.map(\.date).sorted()
            var interval: Double?
            if let first = dates.first, let last = dates.last, dates.count > 1 {
                let span = last.timeIntervalSince(first)
                if span > 0 { interval = span / Double(dates.count - 1) / 86400 }
            }

            requests.append(
                SenderClassificationRequest(
                    senderEmail: sender,
                    displayName: senderEmails.first?.sender ?? sender,
                    sampleSubjects: Array(subjects),
                    totalEmails: senderEmails.count,
                    hasUnsubscribe: senderEmails.contains(where: \.hasListUnsubscribe),
                    averageIntervalDays: interval
                )
            )
        }
        return requests
    }

    // MARK: - Merge

    /// Combine a rule result with a model verdict, never loosening safety.
    ///
    /// The tier is `max(ruleTier, verdictTier)` on the strictness ordering. So the model
    /// can promote mail to review or protected on its own authority, but moving mail
    /// toward deletion requires the rules to already agree it is safe.
    static func merge(
        rule: CategorizationResult,
        verdict: SenderVerdict,
        providerCategory: ProviderCategory? = nil
    ) -> CategorizationResult {
        // A contact outranks any verdict, and nothing here may weaken that.
        guard rule.safetyTier != .protected_ else { return rule }

        let ruleRank = strictness(rule.safetyTier)
        let verdictRank = strictness(verdict.impliedTier)

        // Narrowing-only applies to findings the rules actually EARNED. A weak finding is
        // provisional — the invariant parked it in review because the rules did not know —
        // so a verdict may resolve it in either direction.
        //
        // But a verdict alone may not authorise DELETION. The principle is that no single
        // fallible source gets to do that: an explicit domain list may, because it is
        // near-certain and language-independent; one model call may not, because a
        // hallucinated "disposable" would cost a real receipt. So loosening requires the
        // provider to independently agree the mail is bulk marketing — two unrelated
        // classifiers reaching the same conclusion, one of which read the message.
        //
        // Both failure modes here have already happened. Applying narrowing to provisional
        // findings froze the whole mailbox in review (1 of 403 actionable, including 104
        // the model had correctly called marketing). Letting the model loosen freely is
        // what the test guarding this line was written to prevent.
        let finalTier: SafetyTier
        if rule.evidence.canAutoAction {
            finalTier = verdictRank > ruleRank ? verdict.impliedTier : rule.safetyTier
        } else if verdictRank > ruleRank {
            // Raising safety never needs a second opinion.
            finalTier = verdict.impliedTier
        } else if verdict.impliedTier == .safe && providerCategory?.isBulkMarketing == true {
            finalTier = .safe
        } else {
            finalTier = rule.safetyTier
        }

        let useVerdictCategory = !rule.evidence.canAutoAction
        let finalCategory = useVerdictCategory ? verdict.category : rule.category

        let reason = useVerdictCategory ? "AI: \(verdict.reason)" : rule.reason
        let tierNote: String
        if finalTier != rule.safetyTier && verdictRank > ruleRank {
            tierNote = " (AI raised safety)"
        } else if finalTier == .safe && rule.safetyTier != .safe {
            tierNote = " (AI and Gmail agree it is bulk marketing)"
        } else {
            tierNote = ""
        }

        return CategorizationResult(
            messageId: rule.messageId,
            category: finalCategory,
            safetyTier: finalTier,
            confidence: useVerdictCategory ? verdict.confidence : rule.confidence,
            reason: reason + tierNote,
            // A verdict counts as strong evidence: something read the mail, rather than
            // pattern-matching its envelope.
            evidence: useVerdictCategory ? .strong : rule.evidence
        )
    }

    static func strictness(_ tier: SafetyTier) -> Int {
        switch tier {
        case .safe: return 0
        case .review: return 1
        case .protected_: return 2
        }
    }
}

// MARK: - Cache

/// Storage for model verdicts, keyed by model and prompt version.
public protocol SenderVerdictCaching: Sendable {
    func cachedVerdicts(
        accountId: Int64,
        senderEmails: [String],
        modelId: String,
        promptVersion: String
    ) async throws -> [String: SenderVerdict]

    func storeVerdicts(
        _ verdicts: [SenderVerdict],
        accountId: Int64,
        modelId: String,
        promptVersion: String
    ) async throws
}

// MARK: - Chunking

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
