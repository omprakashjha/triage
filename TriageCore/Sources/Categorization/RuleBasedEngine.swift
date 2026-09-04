import Foundation

// MARK: - Protocol

/// Protocol for email categorization engines.
/// The rule-based engine is the default (free). AI engine is premium.
public protocol CategorizationEngine: Sendable {
    /// Categorize a batch of emails, returning results with confidence scores
    func categorize(emails: [EmailMetadata]) async throws -> [CategorizationResult]
}

/// Result of categorizing a single email
public struct CategorizationResult: Sendable {
    public let messageId: String
    public let category: EmailCategory
    public let safetyTier: SafetyTier
    public let confidence: Double  // 0.0 - 1.0
    public let reason: String      // Human-readable reason for the categorization

    public init(
        messageId: String,
        category: EmailCategory,
        safetyTier: SafetyTier,
        confidence: Double,
        reason: String
    ) {
        self.messageId = messageId
        self.category = category
        self.safetyTier = safetyTier
        self.confidence = confidence
        self.reason = reason
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

    private func categorizeEmail(_ email: EmailMetadata) -> CategorizationResult {
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
                reason: "From known contact"
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
                reason: "Transactional sender with a List-Unsubscribe header"
            )
        }

        // Only strong promotional evidence justifies the auto-actionable tier.
        if senderPatterns.promotionalMatch(domain).isStrong {
            return CategorizationResult(
                messageId: email.messageId,
                category: .promotion,
                safetyTier: .safe,
                confidence: 0.9,
                reason: "Promotional sender with List-Unsubscribe"
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
                reason: "Transactional sender"
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
                    : "Known promotional sender domain"
            )
        }

        // 4. Notification and social outrank a generic-subdomain guess.
        if senderPatterns.isNotificationSender(email: email.senderEmail, domain: domain) {
            return CategorizationResult(
                messageId: email.messageId,
                category: .notification,
                safetyTier: .safe,
                confidence: 0.8,
                reason: "Known notification sender"
            )
        }

        if senderPatterns.isSocialPlatform(domain: domain) {
            return CategorizationResult(
                messageId: email.messageId,
                category: .social,
                safetyTier: .safe,
                confidence: 0.9,
                reason: "Social media platform"
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
                reason: "Mixed sender (\(domain)) with a promotional subject"
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
