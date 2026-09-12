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
    /// The second pass, reported separately so it is visible whether reading individual
    /// messages actually resolved anything.
    public var messageBatchesRequested = 0
    public var messageVerdictsReturned = 0
    public var messagesResolved = 0
    public var failure: String?

    public var summary: String {
        if let failure {
            return "AI pass FAILED after \(verdictsReturned) verdicts: \(failure)"
        }
        var text = "AI: \(sendersConsidered) ambiguous senders, "
            + "\(verdictsFromCache) cached + \(verdictsReturned) fetched in \(batchesRequested) call(s), "
            + "\(mergesApplied) emails merged."
        if messageBatchesRequested > 0 {
            text += " Then read \(messageVerdictsReturned) individual messages in "
                + "\(messageBatchesRequested) call(s), resolving \(messagesResolved)."
        }
        return text
    }
}

public final class AICategorizationEngine: CategorizationEngine {

    /// Rule results at or above this confidence are accepted as-is and never sent to
    /// the model.
    public static let ruleConfidenceCeiling = 0.7

    /// Senders per model call.
    /// How many senders go into one model call.
    ///
    /// Was 50, which was sized for cost rather than quality and got neither. Fifty senders
    /// each carrying eight subjects and a body preview is a very large prompt, and the
    /// model's attention divides across all of them — every sender gets a shallow pass, and
    /// the per-sender reasoning this whole design depends on is exactly what suffers.
    ///
    /// Ten is small enough that a sender's samples can actually be read against each other,
    /// which is what deciding a mixed sender requires. The extra calls are cheap: a real
    /// mailbox needed roughly 76 sender verdicts in total, so this is single-digit call
    /// counts either way, and they are cached per model and prompt version.
    public static let batchSize = 10

    /// How many MESSAGES go into one call.
    ///
    /// Larger than the sender batch because a message request is much smaller — one subject,
    /// one preview, no sample list — and the judgements are more independent of each other, so
    /// dividing attention costs less here than it does when comparing a sender's subjects
    /// against one another.
    public static let messageBatchSize = 20

    private let rules: RuleBasedEngine
    private let transport: LLMTransport
    private let cache: SenderVerdictCaching
    private let accountId: Int64
    private let sampleSubjects: (String) async -> [String]
    /// Absent unless the user enabled sending body previews. Deliberately optional rather
    /// than a flag: when disabled there is no code path that reads message content.
    private let sampleSnippets: ((String) async -> [String])?
    /// The user's corrections, re-read per run so a fix made a moment ago reaches the very
    /// next batch.
    private let correctionExamples: () async -> [CorrectionExample]
    /// Reports what the pass did. Called once per `categorize`, success or failure.
    private let onDiagnostics: (@Sendable (AIRunDiagnostics) -> Void)?

    public init(
        rules: RuleBasedEngine,
        transport: LLMTransport,
        cache: SenderVerdictCaching,
        accountId: Int64,
        sampleSubjects: @escaping (String) async -> [String] = { _ in [] },
        sampleSnippets: ((String) async -> [String])? = nil,
        correctionExamples: @escaping () async -> [CorrectionExample] = { [] },
        onDiagnostics: (@Sendable (AIRunDiagnostics) -> Void)? = nil
    ) {
        self.rules = rules
        self.transport = transport
        self.cache = cache
        self.accountId = accountId
        self.sampleSubjects = sampleSubjects
        self.sampleSnippets = sampleSnippets
        self.correctionExamples = correctionExamples
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

    /// Read and decide the messages the sender-level pass left undecided.
    ///
    /// "Undecided" means still in `review` — which, since a keep decision now lands in
    /// `protected_`, is exactly the set nobody has ruled on. Mail the user corrected never
    /// reaches here: those are settled by a wrapper outside this engine.
    private func classifyUndecidedMessages(
        emails: [EmailMetadata],
        resultsById: inout [String: CategorizationResult],
        diagnostics: inout AIRunDiagnostics
    ) async throws {
        let undecided = emails.filter { email in
            guard let result = resultsById[email.messageId] else { return false }
            return result.safetyTier == .review
        }
        guard !undecided.isEmpty else { return }

        let learned = await correctionExamples()
        let now = Date()

        var requests: [MessageClassificationRequest] = []
        var providerByMessageId: [String: ProviderCategory] = [:]
        for email in undecided {
            let ageDays = Int(now.timeIntervalSince(email.date) / 86400)
            if let provider = email.providerCategory {
                providerByMessageId[email.messageId] = provider
            }
            requests.append(
                MessageClassificationRequest(
                    messageId: email.messageId,
                    senderEmail: email.senderEmail,
                    displayName: email.sender,
                    subject: email.subject,
                    // Only when the user allowed body previews, on the same terms as the
                    // sender pass — the closure is absent otherwise, so there is no path
                    // that reads message content without consent.
                    snippet: sampleSnippets == nil ? nil : email.snippet,
                    ageDays: max(0, ageDays),
                    providerCategory: email.providerCategory,
                    senderVerdictSummary: resultsById[email.messageId]?.reason,
                    hasUnsubscribe: email.hasListUnsubscribe
                )
            )
        }

        for batch in requests.chunked(into: Self.messageBatchSize) {
            diagnostics.messageBatchesRequested += 1
            let verdicts = try await transport.classify(messages: batch, corrections: learned)
            diagnostics.messageVerdictsReturned += verdicts.count

            for verdict in verdicts {
                guard let rule = resultsById[verdict.messageId] else { continue }
                resultsById[verdict.messageId] = Self.mergeMessage(
                    rule: rule,
                    verdict: verdict,
                    // Must be passed, not defaulted. Omitting it left every disposable verdict
                    // uncorroborated and therefore stuck in review, which would have made this
                    // whole pass produce no visible movement — the exact complaint it exists
                    // to answer.
                    providerCategory: providerByMessageId[verdict.messageId]
                )
                diagnostics.messagesResolved += 1
            }
        }
    }

    /// Fold a message-level verdict into the result.
    ///
    /// The same asymmetry as everywhere else, for the same reason: the model may settle mail
    /// as KEEP on its own, because that direction cannot lose anything. Moving mail toward
    /// deletion still needs a second source — here the provider agreeing it is bulk
    /// marketing — because one model call, however well informed, is a single fallible
    /// source and a hallucinated "disposable" costs a real message.
    ///
    /// Reaching this point means the sender pass could not decide, so there is no earned
    /// finding to protect and the verdict is free to resolve it in the keep direction.
    static func mergeMessage(
        rule: CategorizationResult,
        verdict: MessageVerdict,
        providerCategory: ProviderCategory? = nil
    ) -> CategorizationResult {
        guard rule.safetyTier != .protected_ else { return rule }

        // An abstention at message level too: nothing read, nothing decided, stays pending.
        if verdict.isUnsure {
            return CategorizationResult(
                messageId: rule.messageId,
                category: rule.category,
                safetyTier: .review,
                confidence: rule.confidence,
                reason: rule.reason + " — the model read this message and still could not tell",
                evidence: .weak
            )
        }

        let tier: SafetyTier
        if verdict.mustKeep {
            tier = .protected_
        } else if providerCategory?.isBulkMarketing == true {
            tier = .safe
        } else {
            // Decided disposable, uncorroborated: the category is recorded so the user can see
            // the judgement, but it does not become auto-actionable on one source alone.
            tier = .review
        }

        return CategorizationResult(
            messageId: rule.messageId,
            category: verdict.category,
            safetyTier: tier,
            confidence: verdict.confidence,
            reason: "AI read this message: \(verdict.reason)",
            evidence: .strong
        )
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
            let learned = await correctionExamples()
            for batch in requests.chunked(into: Self.batchSize) {
                diagnostics.batchesRequested += 1
                let fresh = try await transport.classify(senders: batch, corrections: learned)
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
                // Resolved PER MESSAGE. Where the model named a subject split, this is
                // where a mixed sender stops being one answer and becomes two: the
                // marketing half and the receipts half of the same address get different
                // verdicts from a single sender-level call.
                verdict: verdict.resolved(forSubject: email.subject),
                // Also per message: the provider labelled each one individually.
                providerCategory: email.providerCategory
            )
            diagnostics.mergesApplied += 1
        }

        // SECOND PASS: read the messages the sender pass could not decide.
        //
        // Sender-level classification has a ceiling that a real mailbox walked into. A rail
        // operator's subject patterns matched a handful of its 54 messages, because that
        // sender writes fresh marketing copy every week — "Maak kans op een jaar gratis
        // treinen!" is unmistakably promotional and matches no pattern anyone would have
        // written in advance. No pattern set generalises over editorial variety; reading the
        // message does.
        //
        // Scoped deliberately to the undecided residue. It is the only mail where this buys
        // anything, and it keeps the call count proportional to what is actually unresolved
        // rather than to mailbox size.
        try await classifyUndecidedMessages(
            emails: emails,
            resultsById: &resultsById,
            diagnostics: &diagnostics
        )

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
            var subjects = Self.representativeSubjects(of: senderEmails)
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
                    averageIntervalDays: interval,
                    // Only fetched when the user has allowed it. The closure is absent
                    // rather than returning empty when disabled, so the code path that
                    // reads message content does not exist unless it was turned on.
                    sampleSnippets: await sampleSnippets?(sender) ?? [],
                    // Counted from the mail already in hand rather than queried: the
                    // provider's own labels are the strongest available hint that a sender
                    // is mixed, and a mixed sender is one the model should split.
                    providerLabelCounts: Self.providerCounts(of: senderEmails),
                    userHasReplied: senderEmails.contains {
                        $0.labels?.contains("SENT") ?? false
                    }
                )
            )
        }
        return requests
    }

    /// Subjects spread across a sender's history, newest first, deduplicated.
    ///
    /// Taking the newest N was actively misleading. A rail operator's most recent eight
    /// subjects were all winter promotions, so the model saw a seasonal marketing sender and
    /// produced fragments describing that one campaign — none of which matched the operator's
    /// year-round receipts and service alerts. Sampling evenly across the date range shows
    /// what the sender actually does over time, which is the only basis on which a
    /// generalising rule can be written.
    ///
    /// Near-duplicate subjects are collapsed to their leading words, because twelve
    /// "Daily Activity Statement for <date>" messages teach the model nothing that one does,
    /// while crowding out the variety that would.
    static func representativeSubjects(of emails: [EmailMetadata], limit: Int = 20) -> [String] {
        guard !emails.isEmpty else { return [] }

        let stride = max(1, emails.count / limit)
        var picked: [String] = []
        var seenShapes: Set<String> = []

        for (index, email) in emails.enumerated() where index % stride == 0 {
            // Collapse by the first four words, which is what makes a template recognisable
            // while still telling apart genuinely different subjects.
            let shape = email.subject
                .lowercased()
                .split(whereSeparator: { $0 == " " })
                .prefix(4)
                .joined(separator: " ")
            guard seenShapes.insert(shape).inserted else { continue }
            picked.append(email.subject)
            if picked.count >= limit { break }
        }

        // A sender whose mail is nearly all one template yields very few shapes; top up from
        // the newest so the model is not judging on two examples.
        if picked.count < 5 {
            for email in emails where !picked.contains(email.subject) {
                picked.append(email.subject)
                if picked.count >= 5 { break }
            }
        }
        return picked
    }

    static func providerCounts(of emails: [EmailMetadata]) -> [String: Int] {        var counts: [String: Int] = [:]
        for email in emails {
            if let category = email.providerCategory {
                counts[category.displayName, default: 0] += 1
            }
        }
        return counts
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

        // An abstention is an ABSENCE of a verdict, not a verdict, so it may not move the
        // tier in either direction — it has nothing to move it with. Letting it do so was a
        // real regression: the model's "this sender is mixed and this subject matched
        // neither of my patterns" was raising safety over mail that BOTH the rules and the
        // provider had independently called marketing, which held 48 emails out of the
        // actionable tier and left the app unable to clean anything.
        //
        // Mail the rules were also unsure about is unaffected: its tier is already review,
        // so leaving it untouched is the same outcome by a more honest route.
        if verdict.isUnsure {
            return CategorizationResult(
                messageId: rule.messageId,
                category: rule.category,
                safetyTier: rule.safetyTier,
                confidence: rule.confidence,
                reason: rule.reason + " — the model had no read on this message",
                evidence: rule.evidence
            )
        }

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
