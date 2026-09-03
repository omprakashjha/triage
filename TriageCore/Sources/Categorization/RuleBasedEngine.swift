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
        if isAutomatedSender(email) {
            return CategorizationResult(
                messageId: email.messageId,
                category: .notification,
                safetyTier: .safe,
                confidence: 0.7,
                reason: "Automated sender (noreply/no-reply)"
            )
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

    private func classifyWithUnsubscribe(_ email: EmailMetadata) -> CategorizationResult {
        let domain = EmailHeaderParser.extractDomain(email.senderEmail)

        // Check if it's a promotional domain even though it has unsubscribe
        if senderPatterns.isPromotionalDomain(domain) {
            return CategorizationResult(
                messageId: email.messageId,
                category: .promotion,
                safetyTier: .safe,
                confidence: 0.9,
                reason: "Promotional sender with List-Unsubscribe"
            )
        }

        // Default: newsletter (has unsubscribe but not clearly promotional)
        return CategorizationResult(
            messageId: email.messageId,
            category: .newsletter,
            safetyTier: .safe,
            confidence: 0.85,
            reason: "Has List-Unsubscribe header"
        )
    }

    private func matchSenderPattern(_ email: EmailMetadata) -> CategorizationResult? {
        let domain = EmailHeaderParser.extractDomain(email.senderEmail)
        let localPart = email.senderEmail.components(separatedBy: "@").first ?? ""

        // Promotional domains
        if senderPatterns.isPromotionalDomain(domain) {
            return CategorizationResult(
                messageId: email.messageId,
                category: .promotion,
                safetyTier: .safe,
                confidence: 0.85,
                reason: "Known promotional sender domain"
            )
        }

        // Notification patterns
        if senderPatterns.isNotificationSender(email: email.senderEmail, domain: domain) {
            return CategorizationResult(
                messageId: email.messageId,
                category: .notification,
                safetyTier: .safe,
                confidence: 0.8,
                reason: "Known notification sender"
            )
        }

        // Social media
        if senderPatterns.isSocialPlatform(domain: domain) {
            return CategorizationResult(
                messageId: email.messageId,
                category: .social,
                safetyTier: .safe,
                confidence: 0.9,
                reason: "Social media platform"
            )
        }

        // Transactional (receipts, shipping, banking)
        if senderPatterns.isTransactionalDomain(domain) {
            return CategorizationResult(
                messageId: email.messageId,
                category: .transactional,
                safetyTier: .review,
                confidence: 0.75,
                reason: "Transactional sender"
            )
        }

        return nil
    }

    private func matchSubjectPattern(_ email: EmailMetadata) -> CategorizationResult? {
        let subject = email.subject.lowercased()

        // Promotional subject patterns
        let promoPatterns = [
            "% off", "sale", "deal", "discount", "limited time",
            "flash sale", "buy now", "shop now", "free shipping",
            "exclusive offer", "save up to", "clearance",
            "black friday", "cyber monday", "promo code",
        ]
        for pattern in promoPatterns {
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

        // Notification subject patterns
        let notificationPatterns = [
            "your order", "shipping confirmation", "delivery update",
            "password reset", "verify your", "confirm your",
            "security alert", "login attempt", "new sign-in",
            "account update", "action required",
        ]
        for pattern in notificationPatterns {
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

        // Transactional subject patterns
        let transactionalPatterns = [
            "receipt", "invoice", "payment", "statement",
            "your bill", "subscription", "renewal",
        ]
        for pattern in transactionalPatterns {
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

        // Newsletter subject patterns
        let newsletterPatterns = [
            "weekly digest", "daily digest", "newsletter",
            "this week in", "monthly update", "weekly roundup",
            "issue #", "edition", "digest",
        ]
        for pattern in newsletterPatterns {
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

    private func isAutomatedSender(_ email: EmailMetadata) -> Bool {
        let localPart = email.senderEmail.components(separatedBy: "@").first ?? ""
        let automatedPrefixes = [
            "noreply", "no-reply", "no_reply", "donotreply", "do-not-reply",
            "notifications", "notification", "alerts", "alert",
            "mailer", "automail", "auto", "system", "info",
            "updates", "news", "marketing", "promo",
        ]
        return automatedPrefixes.contains { localPart.lowercased().hasPrefix($0) }
    }
}
