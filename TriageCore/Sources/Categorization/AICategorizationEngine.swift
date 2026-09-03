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

    public init(
        rules: RuleBasedEngine,
        transport: LLMTransport,
        cache: SenderVerdictCaching,
        accountId: Int64,
        sampleSubjects: @escaping (String) async -> [String] = { _ in [] }
    ) {
        self.rules = rules
        self.transport = transport
        self.cache = cache
        self.accountId = accountId
        self.sampleSubjects = sampleSubjects
    }

    public func categorize(emails: [EmailMetadata]) async throws -> [CategorizationResult] {
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
        guard !ambiguousSenders.isEmpty else { return ruleResults }

        // Cached verdicts cost nothing — a rescan should not re-pay for a sender
        // already judged by this model and prompt.
        var verdicts = try await cache.cachedVerdicts(
            accountId: accountId,
            senderEmails: ambiguousSenders,
            modelId: transport.modelId,
            promptVersion: transport.promptVersion
        )

        let uncached = ambiguousSenders.filter { verdicts[$0] == nil }
        if !uncached.isEmpty {
            let requests = await buildRequests(for: uncached, emails: emails)
            for batch in requests.chunked(into: Self.batchSize) {
                let fresh = try await transport.classify(senders: batch)
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
            resultsById[email.messageId] = Self.merge(rule: ruleResult, verdict: verdict)
        }

        // Preserve input order.
        return emails.compactMap { resultsById[$0.messageId] }
    }

    // MARK: - Selection

    /// Senders whose mail the rules could not confidently resolve.
    ///
    /// Protected mail is excluded: a contact is already settled, and there is no
    /// verdict the model could return that would improve on that.
    static func sendersNeedingClassification(
        emails: [EmailMetadata],
        ruleResults: [String: CategorizationResult]
    ) -> [String] {
        var senders: Set<String> = []
        for email in emails {
            guard let result = ruleResults[email.messageId] else { continue }
            if result.safetyTier == .protected_ { continue }
            if result.category == .unknown || result.confidence < ruleConfidenceCeiling {
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
    static func merge(rule: CategorizationResult, verdict: SenderVerdict) -> CategorizationResult {
        let ruleRank = strictness(rule.safetyTier)
        let verdictRank = strictness(verdict.impliedTier)
        let finalTier = verdictRank > ruleRank ? verdict.impliedTier : rule.safetyTier

        // The model only runs where the rules were unconfident, so its category is
        // preferred — but a rule result that was already confident keeps its category.
        let useVerdictCategory = rule.category == .unknown
            || rule.confidence < AICategorizationEngine.ruleConfidenceCeiling
        let finalCategory = useVerdictCategory ? verdict.category : rule.category

        let reason = useVerdictCategory
            ? "AI: \(verdict.reason)"
            : rule.reason
        let tierNote = finalTier != rule.safetyTier && finalTier == verdict.impliedTier
            ? " (AI raised safety)"
            : ""

        return CategorizationResult(
            messageId: rule.messageId,
            category: finalCategory,
            safetyTier: finalTier,
            confidence: useVerdictCategory ? verdict.confidence : rule.confidence,
            reason: reason + tierNote
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
