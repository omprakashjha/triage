import Foundation

// MARK: - Protocol

/// Protocol for email categorization engines.
/// The rule-based engine is the default (free). AI engine is premium.
public protocol CategorizationEngine: Sendable {
    /// Categorize a batch of emails, returning results with confidence scores
    func categorize(emails: [EmailMetadata]) async throws -> [CategorizationResult]
}

/// What kind of evidence a decision rests on.
///
/// This exists because confidence was doing a job it could not do. The confidence values
/// are hand-assigned literals — 0.85 for a domain-list hit, 0.7 for an English subject
/// keyword — and nothing measured them. Using a numeric threshold to decide when to ask
/// the AI therefore meant a baseless 0.85 outranked the one component able to read the
/// mail, which is how a Dutch water bill became an auto-actionable newsletter.
///
/// Measured on a real 403-email mailbox: only 20% of decisions rested on structural
/// evidence. The rest came from an unsubscribe header, a `noreply@` prefix, or an
/// English keyword in a substantially Dutch inbox.
public enum EvidenceStrength: String, Sendable, Codable, Equatable {
    /// The sender is explicitly known: a listed domain, a marketing platform, a contact.
    /// Language-independent and safe to act on.
    case strong
    /// A heuristic fired, but it says little about whether the mail matters. An
    /// unsubscribe header proves BULK not DISPOSABLE; `noreply@` proves nobody reads
    /// replies, not that the content is worthless; an English keyword proves nothing at
    /// all in a mailbox that is not in English.
    case weak
    /// Nothing matched.
    case none

    /// Only strong evidence may put mail in the auto-actionable tier without a model or
    /// a human having looked at it.
    public var canAutoAction: Bool { self == .strong }
}

/// Result of categorizing a single email
public struct CategorizationResult: Sendable {
    public let messageId: String
    public let category: EmailCategory
    public let safetyTier: SafetyTier
    public let confidence: Double  // 0.0 - 1.0
    public let reason: String      // Human-readable reason for the categorization
    /// What the decision actually rests on. Drives whether the AI is consulted.
    public let evidence: EvidenceStrength

    public init(
        messageId: String,
        category: EmailCategory,
        safetyTier: SafetyTier,
        confidence: Double,
        reason: String,
        evidence: EvidenceStrength = .weak
    ) {
        self.messageId = messageId
        self.category = category
        self.safetyTier = safetyTier
        self.confidence = confidence
        self.reason = reason
        self.evidence = evidence
    }
}

// MARK: - Rule-Based Engine

/// Default categorization engine using header analysis, sender patterns, and heuristics.
/// No external dependencies — works fully offline.
public final class RuleBasedEngine: CategorizationEngine, @unchecked Sendable {
    private let senderPatterns: SenderPatternDatabase
    private let knownContacts: Set<String>

    public init(
        senderPatterns: SenderPatternDatabase = .default,
        knownContacts: Set<String> = []
    ) {
        self.senderPatterns = senderPatterns
        self.knownContacts = knownContacts
    }

    /// Create a new engine with updated contacts
    public func withContacts(_ contacts: Set<String>) -> RuleBasedEngine {
        RuleBasedEngine(senderPatterns: senderPatterns, knownContacts: contacts)
    }

    public func categorize(emails: [EmailMetadata]) async throws -> [CategorizationResult] {
        emails.map { categorizeEmail($0) }
    }

    // MARK: - Core Classification Logic

    /// Classify, then enforce the evidence invariant.
    ///
    /// A single chokepoint rather than trusting ~15 call sites to get the tier right:
    /// the auto-actionable tier now REQUIRES strong evidence, so a heuristic can suggest
    /// a category but cannot authorise acting on it. This is what stops the next
    /// unexamined weak rule from quietly producing another deletable water bill.
    private func categorizeEmail(_ email: EmailMetadata) -> CategorizationResult {
        let ruled = classify(email)
        let languageChecked = Self.discountingEnglishPatternsOnForeignMail(ruled, email: email)
        let corroborated = Self.weighingProviderOpinion(languageChecked, email: email)
        return Self.enforcingEvidenceInvariant(corroborated)
    }

    /// Withdraw trust from a subject-derived verdict when the subject is not English.
    ///
    /// The engine's subject patterns are English strings, so on non-English mail a match is
    /// as likely to be coincidence as comprehension. Rather than pretend otherwise, the
    /// finding is kept as a suggestion and stripped of the authority to act — which also
    /// pushes the sender to the model, the only component that can actually read it.
    ///
    /// Only SUBJECT-derived findings are affected. A listed domain means the same thing in
    /// every language, so `chase.com` and `rabobank.nl` are untouched by this.
    static func discountingEnglishPatternsOnForeignMail(
        _ result: CategorizationResult,
        email: EmailMetadata
    ) -> CategorizationResult {
        guard result.evidence == .strong,
              result.reason.lowercased().contains("subject"),
              subjectIsProbablyNotEnglish(email.subject)
        else { return result }

        return CategorizationResult(
            messageId: result.messageId,
            category: result.category,
            safetyTier: result.safetyTier,
            confidence: min(result.confidence, 0.55),
            reason: result.reason
                + " — but this subject is not in English, so an English keyword match "
                + "proves little",
            evidence: .weak
        )
    }

    /// Reconcile our verdict with the mail provider's own.
    ///
    /// The provider is an independent classifier that works in every language, and it
    /// already labelled every message before we looked at it. Where it agrees, we can act
    /// with more confidence than either source alone justifies; where it contradicts us on
    /// the axis that matters — is this mail disposable — it is the more credible of the
    /// two, because our side is an English keyword list.
    ///
    /// Never used to make mail MORE deletable than the rules found it. A provider
    /// promotions label is corroboration for auto-action only when our own rules
    /// independently reached the same conclusion.
    static func weighingProviderOpinion(
        _ result: CategorizationResult,
        email: EmailMetadata
    ) -> CategorizationResult {
        guard let provider = email.providerCategory else { return result }

        // A contact is already settled by stronger evidence than any label.
        if result.safetyTier == .protected_ { return result }

        let weThinkDisposable = result.category == .promotion || result.category == .newsletter

        // Contradiction on disposability: trust the provider, and say so.
        if weThinkDisposable && provider.arguesForKeeping {
            return CategorizationResult(
                messageId: result.messageId,
                category: result.category,
                safetyTier: .review,
                confidence: 0.4,
                reason: result.reason
                    + " — but Gmail filed it under \(provider.displayName), which is where "
                    + "bills and confirmations go, so this disagreement needs review",
                evidence: .weak
            )
        }

        // Independent agreement: two classifiers, one of them multilingual, same answer.
        if weThinkDisposable && provider.isBulkMarketing {
            return CategorizationResult(
                messageId: result.messageId,
                category: result.category,
                safetyTier: result.safetyTier,
                confidence: max(result.confidence, 0.9),
                reason: result.reason + " — and Gmail also filed it under Promotions",
                evidence: .strong
            )
        }

        if result.category == .social && provider == .social {
            return CategorizationResult(
                messageId: result.messageId,
                category: .social,
                safetyTier: result.safetyTier,
                confidence: max(result.confidence, 0.9),
                reason: result.reason + " — and Gmail also filed it under Social",
                evidence: .strong
            )
        }

        return result
    }

    static func enforcingEvidenceInvariant(_ result: CategorizationResult) -> CategorizationResult {
        guard result.safetyTier == .safe, !result.evidence.canAutoAction else { return result }
        return CategorizationResult(
            messageId: result.messageId,
            category: result.category,
            safetyTier: .review,
            // Cap the reported confidence too, so it cannot sit above the AI threshold
            // and block the one component that can actually read this mail.
            confidence: min(result.confidence, 0.6),
            reason: result.reason + " — heuristic only, needs review",
            evidence: result.evidence
        )
    }

    /// Whether a subject is probably not in English.
    ///
    /// Crude on purpose — it only has to be right often enough to stop an English keyword
    /// list being trusted on mail it cannot read. Function words are the signal: they are
    /// short, extremely common, and unlike content words they do not migrate into other
    /// languages' marketing copy.
    ///
    /// The failure this prevents is specific. An English pattern can match a non-English
    /// subject by coincidence — a brand name, a loanword, a shared word like "sale" or
    /// "offer" — and the match then carries the full confidence of a real hit. On a mailbox
    /// where most mail is not English, that is a steady source of confident errors, and
    /// each one also blocks the model from being consulted.
    static func subjectIsProbablyNotEnglish(_ subject: String) -> Bool {
        let lowered = subject.lowercased()

        // Dutch, German, French, Spanish, Italian, Portuguese function words.
        let markers = [
            " uw ", " je ", " jouw ", " voor ", " van ", " het ", " een ", " naar ", " bij ",
            " zijn ", " wordt ", " onze ",
            " der ", " die ", " das ", " und ", " für ", " ihre ", " mit ", " sie ", " ihr ",
            " von ", " zum ",
            " le ", " la ", " les ", " des ", " pour ", " avec ", " vous ", " votre ", " sur ",
            " el ", " los ", " las ", " para ", " con ", " sus ", " una ",
            " il ", " lo ", " gli ", " per ", " con ", " sua ",
            " do ", " da ", " dos ", " para ", " com ", " sua ",
        ]
        let padded = " \(lowered) "
        if markers.contains(where: { padded.contains($0) }) { return true }

        // Characters that do not occur in ordinary English text.
        let nonEnglishScalars = CharacterSet(charactersIn: "àâäåæçèéêëìîïñòôöøùûüýÿßœ")
        return lowered.unicodeScalars.contains { nonEnglishScalars.contains($0) }
    }

    private func classify(_ email: EmailMetadata) -> CategorizationResult {
        // Priority order of rules (first match wins):
        // 1. Known contact → PERSONAL + PROTECTED
        // 2. List-Unsubscribe header → NEWSLETTER
        // 3. Sender pattern match (promotional domain, notification pattern, social)
        // 4. Subject pattern match
        // 5. Fallback → UNKNOWN + REVIEW

        // Rule 1: Known contacts
        if isKnownContact(email) {
            return CategorizationResult(
                messageId: email.messageId,
                category: .personal,
                safetyTier: .protected_,
                confidence: 0.95,
                reason: "From known contact",
                evidence: .strong
            )
        }

        // Rule 2: List-Unsubscribe header
        if email.hasListUnsubscribe {
            let subcategory = classifyWithUnsubscribe(email)
            return subcategory
        }

        // Rule 3: Sender pattern matching
        if let patternResult = matchSenderPattern(email) {
            return patternResult
        }

        // Rule 4: Subject pattern matching
        if let subjectResult = matchSubjectPattern(email) {
            return subjectResult
        }

        // Rule 5: Automated sender detection (noreply, no-reply, etc.)
        switch automatedSenderStrength(email) {
        case .strong:
            return CategorizationResult(
                messageId: email.messageId,
                category: .notification,
                safetyTier: .safe,
                confidence: 0.7,
                reason: "Automated sender (noreply/no-reply)"
            )
        case .weak:
            // `info@`, `auto…`, `news…` are frequently real people at small businesses.
            // Categorize, but never auto-delete on this evidence alone.
            return CategorizationResult(
                messageId: email.messageId,
                category: .notification,
                safetyTier: .review,
                confidence: 0.45,
                reason: "Possibly automated sender — ambiguous local part, needs review"
            )
        case .none:
            break
        }

        // Fallback: Unknown
        return CategorizationResult(
            messageId: email.messageId,
            category: .unknown,
            safetyTier: .review,
            confidence: 0.3,
            reason: "No matching rule"
        )
    }

    // MARK: - Rule Implementations

    private func isKnownContact(_ email: EmailMetadata) -> Bool {
        knownContacts.contains(email.senderEmail.lowercased())
    }

    /// Classify an email that carries a `List-Unsubscribe` header.
    ///
    /// The header is strong evidence of *bulk* mail but NOT evidence of *disposable* mail:
    /// order confirmations and statements increasingly ship one-click unsubscribe too. So a
    /// transactional subject wins over the header.
    private func classifyWithUnsubscribe(_ email: EmailMetadata) -> CategorizationResult {
        let domain = EmailHeaderParser.extractDomain(email.senderEmail)

        // A receipt with an unsubscribe link is still a receipt.
        if Self.subjectSuggestsTransactional(email.subject) {
            return CategorizationResult(
                messageId: email.messageId,
                category: .transactional,
                safetyTier: .review,
                confidence: 0.7,
                reason: "Transactional subject, despite a List-Unsubscribe header"
            )
        }

        // Mixed senders get the subject tie-breaker.
        if senderPatterns.isMixedSender(domain: domain) {
            return classifyMixedSender(email, domain: domain)
        }

        if senderPatterns.isTransactionalDomain(domain) {
            return CategorizationResult(
                messageId: email.messageId,
                category: .transactional,
                safetyTier: .review,
                confidence: 0.7,
                reason: "Transactional sender with a List-Unsubscribe header",
                evidence: .strong
            )
        }

        // Only strong promotional evidence justifies the auto-actionable tier.
        if senderPatterns.promotionalMatch(domain).isStrong {
            return CategorizationResult(
                messageId: email.messageId,
                category: .promotion,
                safetyTier: .safe,
                confidence: 0.9,
                reason: "Promotional sender with List-Unsubscribe",
                evidence: .strong
            )
        }

        // Positive evidence of an actual newsletter keeps the auto-actionable tier, so
        // genuine digests are still cleaned up without a review step.
        let subject = email.subject.lowercased()
        if let pattern = Self.newsletterSubjectPatterns.first(where: { subject.contains($0) }) {
            return CategorizationResult(
                messageId: email.messageId,
                category: .newsletter,
                safetyTier: .safe,
                confidence: 0.85,
                reason: "Newsletter subject (\"\(pattern)\") with List-Unsubscribe"
            )
        }

        // Fallback: bulk mail from a sender we do not recognise.
        //
        // This used to return newsletter/.safe at 0.85, which was wrong twice over. A
        // `List-Unsubscribe` header proves mail is BULK, not that it is DISPOSABLE —
        // utilities, insurers and banks all send statements with one. Real example:
        // "Jaarafrekening van waterbedrijf Vitens" (an annual water bill) from
        // noreply@mail.vitens.nl was classified newsletter/.safe at 0.85 confidence.
        //
        // The high confidence made it worse than a mere mislabel: 0.85 sits above the
        // AI engine's ambiguity threshold, so the sender was never sent for
        // classification and the model — which reads Dutch perfectly well — never got
        // the chance to correct it. Low confidence here is what routes these senders to
        // the AI, and .review is what stops them being auto-actioned in the meantime.
        return CategorizationResult(
            messageId: email.messageId,
            category: .newsletter,
            safetyTier: .review,
            confidence: 0.5,
            reason: "Bulk mail (List-Unsubscribe) from an unrecognised sender — "
                + "bulk does not mean disposable, so this needs review"
        )
    }

    /// Sender-based classification.
    ///
    /// Order is deliberate and load-bearing:
    /// 1. mixed senders (Amazon et al) — domain cannot decide, ask the subject
    /// 2. transactional — before promotional, so `mail.chase.com` is not swept up by
    ///    the generic `mail.` subdomain heuristic
    /// 3. STRONG promotional (explicitly listed domain or marketing platform)
    /// 4. notification / social — real signals, must beat a generic subdomain guess
    /// 5. WEAK promotional (generic `mail.`/`email.` transport only) → review, never auto-delete
    private func matchSenderPattern(_ email: EmailMetadata) -> CategorizationResult? {
        let domain = EmailHeaderParser.extractDomain(email.senderEmail)

        // 1. Mixed senders: the domain sends both kinds, so break the tie on the subject.
        if senderPatterns.isMixedSender(domain: domain) {
            return classifyMixedSender(email, domain: domain)
        }

        // 2. Transactional before promotional.
        if senderPatterns.isTransactionalDomain(domain) {
            return CategorizationResult(
                messageId: email.messageId,
                category: .transactional,
                safetyTier: .review,
                confidence: 0.75,
                reason: "Transactional sender",
                evidence: .strong
            )
        }

        let promoStrength = senderPatterns.promotionalMatch(domain)

        // 3. Strong promotional evidence.
        if promoStrength.isStrong {
            return CategorizationResult(
                messageId: email.messageId,
                category: .promotion,
                safetyTier: .safe,
                confidence: 0.85,
                reason: promoStrength == .platform
                    ? "Sent via a bulk-marketing platform"
                    : "Known promotional sender domain",
                evidence: .strong
            )
        }

        // 4. Notification and social outrank a generic-subdomain guess.
        if senderPatterns.isNotificationSender(email: email.senderEmail, domain: domain) {
            return CategorizationResult(
                messageId: email.messageId,
                category: .notification,
                safetyTier: .safe,
                confidence: 0.8,
                reason: "Known notification sender",
                evidence: .strong
            )
        }

        if senderPatterns.isSocialPlatform(domain: domain) {
            return CategorizationResult(
                messageId: email.messageId,
                category: .social,
                safetyTier: .safe,
                confidence: 0.9,
                reason: "Social media platform",
                evidence: .strong
            )
        }

        // 5. Weak evidence only: categorize but require approval.
        if promoStrength == .generic {
            return CategorizationResult(
                messageId: email.messageId,
                category: .promotion,
                safetyTier: .review,
                confidence: 0.5,
                reason: "Generic bulk-mail subdomain (\(domain)) — weak signal, needs review"
            )
        }

        return nil
    }

    /// Decide a mixed sender (one domain, both promotional and transactional mail) by subject.
    ///
    /// When the subject gives no signal we return promotion but at `.review`, because
    /// the cost of deleting an order record far exceeds the cost of one extra approval.
    private func classifyMixedSender(_ email: EmailMetadata, domain: String) -> CategorizationResult {
        if Self.subjectSuggestsTransactional(email.subject) {
            return CategorizationResult(
                messageId: email.messageId,
                category: .transactional,
                safetyTier: .review,
                confidence: 0.8,
                reason: "Mixed sender (\(domain)) with a transactional subject"
            )
        }

        if Self.subjectSuggestsPromotional(email.subject) {
            return CategorizationResult(
                messageId: email.messageId,
                category: .promotion,
                safetyTier: .safe,
                confidence: 0.8,
                reason: "Mixed sender (\(domain)) with a promotional subject",
                // Two independent signals agree: the domain is explicitly listed AND the
                // subject is unambiguously promotional. That is the high-volume retailer
                // case, and losing it would gut the app's automatic cleanup for no
                // safety gain — order confirmations from these same senders are caught
                // by the transactional check above.
                evidence: .strong
            )
        }

        return CategorizationResult(
            messageId: email.messageId,
            category: .promotion,
            safetyTier: .review,
            confidence: 0.45,
            reason: "Mixed sender (\(domain)) — subject is ambiguous, needs review"
        )
    }

    // MARK: - Subject Pattern Data

    /// Hoisted to type level so the mixed-sender tie-breaker can reuse them
    /// without re-running full categorization.
    static let promotionalSubjectPatterns = [
        "% off", "sale", "deal", "discount", "limited time",
        "flash sale", "buy now", "shop now", "free shipping",
        "exclusive offer", "save up to", "clearance",
        "black friday", "cyber monday", "promo code",
    ]

    static let notificationSubjectPatterns = [
        "password reset", "verify your", "confirm your",
        "security alert", "login attempt", "new sign-in",
        "account update", "action required",
    ]

    /// Note: order matters against ``notificationSubjectPatterns``. Shipping and order
    /// subjects live here because losing an order record is worse than over-retaining
    /// a notification.
    static let transactionalSubjectPatterns = [
        "receipt", "invoice", "payment", "statement",
        "your bill", "subscription", "renewal",
        "your order", "order confirmation", "shipping confirmation",
        "delivery update", "has shipped", "refund",
    ]

    static let newsletterSubjectPatterns = [
        "weekly digest", "daily digest", "newsletter",
        "this week in", "monthly update", "weekly roundup",
        "issue #", "edition", "digest",
    ]

    /// True when the subject carries a record-keeping signal (receipt, order, invoice).
    static func subjectSuggestsTransactional(_ subject: String) -> Bool {
        let s = subject.lowercased()
        return transactionalSubjectPatterns.contains { s.contains($0) }
    }

    /// True when the subject carries an unambiguous marketing signal.
    static func subjectSuggestsPromotional(_ subject: String) -> Bool {
        let s = subject.lowercased()
        return promotionalSubjectPatterns.contains { s.contains($0) }
    }

    private func matchSubjectPattern(_ email: EmailMetadata) -> CategorizationResult? {
        let subject = email.subject.lowercased()

        // Transactional first: a receipt misfiled as a promotion gets deleted,
        // a promotion misfiled as a receipt only survives an extra cycle.
        for pattern in Self.transactionalSubjectPatterns {
            if subject.contains(pattern) {
                return CategorizationResult(
                    messageId: email.messageId,
                    category: .transactional,
                    safetyTier: .review,
                    confidence: 0.65,
                    reason: "Transactional subject pattern: \"\(pattern)\""
                )
            }
        }

        for pattern in Self.promotionalSubjectPatterns {
            if subject.contains(pattern) {
                return CategorizationResult(
                    messageId: email.messageId,
                    category: .promotion,
                    safetyTier: .safe,
                    confidence: 0.7,
                    reason: "Promotional subject pattern: \"\(pattern)\""
                )
            }
        }

        for pattern in Self.notificationSubjectPatterns {
            if subject.contains(pattern) {
                return CategorizationResult(
                    messageId: email.messageId,
                    category: .notification,
                    safetyTier: .review,
                    confidence: 0.7,
                    reason: "Notification subject pattern: \"\(pattern)\""
                )
            }
        }

        for pattern in Self.newsletterSubjectPatterns {
            if subject.contains(pattern) {
                return CategorizationResult(
                    messageId: email.messageId,
                    category: .newsletter,
                    safetyTier: .safe,
                    confidence: 0.75,
                    reason: "Newsletter subject pattern: \"\(pattern)\""
                )
            }
        }

        return nil
    }

    /// How confident we are that a local part denotes an unattended mailbox.
    enum AutomatedSenderStrength {
        /// Unambiguous — nobody reads `noreply@`.
        case strong
        /// Ambiguous — `info@`, `auto…`, `news…` are also real people at small businesses.
        case weak
        case none
    }

    /// Local parts that are never a human.
    private static let strongAutomatedTokens: Set<String> = [
        "noreply", "no-reply", "no_reply", "donotreply", "do-not-reply",
        "do_not_reply", "notifications", "notification", "mailer-daemon",
        "mailerdaemon", "postmaster", "bounce", "bounces",
    ]

    /// Local parts that *often* denote automation but are genuinely used by people.
    private static let weakAutomatedTokens: Set<String> = [
        "alerts", "alert", "mailer", "automail", "auto", "system", "info",
        "updates", "news", "marketing", "promo", "hello", "contact", "support",
    ]

    /// Match a token against a local part on a token boundary, so `news` matches
    /// `news@` and `news-digest@` but NOT `newsome@` (a surname).
    private static func localPart(_ localPart: String, matchesToken token: String) -> Bool {
        if localPart == token { return true }
        guard localPart.hasPrefix(token) else { return false }
        let next = localPart[localPart.index(localPart.startIndex, offsetBy: token.count)]
        // Only a separator continues an automated token; a letter means a different word.
        return next == "-" || next == "_" || next == "." || next.isNumber || next == "+"
    }

    private func automatedSenderStrength(_ email: EmailMetadata) -> AutomatedSenderStrength {
        let local = (email.senderEmail.components(separatedBy: "@").first ?? "").lowercased()
        guard !local.isEmpty else { return .none }

        if Self.strongAutomatedTokens.contains(where: { Self.localPart(local, matchesToken: $0) }) {
            return .strong
        }
        if Self.weakAutomatedTokens.contains(where: { Self.localPart(local, matchesToken: $0) }) {
            return .weak
        }
        return .none
    }
}
