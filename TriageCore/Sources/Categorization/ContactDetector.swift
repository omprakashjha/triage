import Foundation

/// Detects known contacts by analyzing sent folders and reply patterns.
/// Emails from known contacts are marked PROTECTED — never auto-deleted.
public actor ContactDetector {
    private let database: AppDatabase
    private var knownContacts: Set<String> = []

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Get the current set of known contacts
    public func getKnownContacts() -> Set<String> {
        knownContacts
    }

    /// Rebuild the contact list for an account from all available evidence and persist it.
    ///
    /// Returns the lowercased address set to hand to `RuleBasedEngine(knownContacts:)`.
    /// This is the call that makes the `.protected_` tier reachable at all — with an
    /// empty set, the engine's highest-priority rule can never fire.
    ///
    /// `sentMailContacts` is supplied by the provider layer (see
    /// `GmailService.fetchSentMailContacts`) so this type stays network-free and testable.
    public func refreshAndPersist(
        accountId: Int64,
        sentMailContacts: [KnownContact] = [],
        manualContacts: Set<String> = []
    ) async throws -> Set<String> {
        var toSave: [KnownContact] = sentMailContacts

        // Gmail's own personal classification, as an independent second source.
        let personalSenders = try await database.sendersWithGmailPersonalLabel(accountId: accountId)
        for (email, count) in personalSenders {
            toSave.append(
                KnownContact(
                    accountId: accountId,
                    email: email,
                    source: .gmailPersonalLabel,
                    occurrences: count
                )
            )
        }

        for email in manualContacts {
            toSave.append(
                KnownContact(accountId: accountId, email: email, source: .manual)
            )
        }

        try await database.saveKnownContacts(toSave)

        let persisted = try await database.knownContactEmails(accountId: accountId)
        knownContacts = persisted
        return persisted
    }

    /// Load the already-persisted contact set without doing any detection work.
    /// Used on every scan after the first, so categorization never runs contact-blind.
    public func loadPersistedContacts(accountId: Int64) async throws -> Set<String> {
        let persisted = try await database.knownContactEmails(accountId: accountId)
        knownContacts = persisted
        return persisted
    }

    /// Merge explicitly-supplied address sources into one normalized set.
    ///
    /// Kept for callers (Yahoo/IMAP) that can enumerate sent recipients themselves.
    /// NOTE: an earlier version of this method also consulted a `detectReplyContacts()`
    /// helper that unconditionally returned an empty set — it has been removed rather
    /// than left in place looking like a working source.
    public func buildContactList(
        yahooSentRecipients: Set<String> = [],
        manualContacts: Set<String> = []
    ) -> Set<String> {
        var contacts: Set<String> = []
        contacts.formUnion(yahooSentRecipients)
        contacts.formUnion(manualContacts)
        knownContacts = Set(contacts.map { $0.lowercased() })
        return knownContacts
    }

    /// Analyze sender frequency — senders who email frequently are likely subscriptions, not contacts
    public func buildSenderFrequencyMap(accountId: Int64) async throws -> [String: SenderProfile] {
        let emails = try await database.fetchEmails(
            accountId: accountId,
            limit: 10000,
            offset: 0
        )

        var profileMap: [String: SenderProfileBuilder] = [:]

        for email in emails {
            let key = email.senderEmail.lowercased()
            if profileMap[key] == nil {
                profileMap[key] = SenderProfileBuilder(email: key, senderName: email.sender)
            }
            profileMap[key]?.addEmail(date: email.date, hasUnsubscribe: email.hasListUnsubscribe)
        }

        return profileMap.mapValues { $0.build() }
    }
}

// MARK: - Sender Profile

/// Profile of a sender built from analyzing their email patterns
public struct SenderProfile: Sendable {
    public let email: String
    public let displayName: String
    public let totalEmails: Int
    public let firstSeen: Date
    public let lastSeen: Date
    public let averageFrequencyDays: Double  // Average days between emails
    public let hasUnsubscribeOption: Bool
    public let isLikelyAutomated: Bool

    /// High frequency + unsubscribe = likely newsletter/promo, not a real person
    public var isLikelySubscription: Bool {
        (averageFrequencyDays < 7 && totalEmails > 5) || hasUnsubscribeOption
    }

    /// Low frequency, no unsubscribe = likely a real person
    public var isLikelyPerson: Bool {
        !hasUnsubscribeOption && !isLikelyAutomated && totalEmails < 20
    }
}

/// Builder for constructing sender profiles from email data
private struct SenderProfileBuilder {
    let email: String
    let senderName: String
    var dates: [Date] = []
    var hasUnsubscribe: Bool = false

    mutating func addEmail(date: Date, hasUnsubscribe: Bool) {
        dates.append(date)
        if hasUnsubscribe { self.hasUnsubscribe = true }
    }

    func build() -> SenderProfile {
        let sorted = dates.sorted()
        let first = sorted.first ?? Date()
        let last = sorted.last ?? Date()

        var avgFrequency: Double = 365
        if sorted.count > 1 {
            let totalSpan = last.timeIntervalSince(first)
            avgFrequency = totalSpan / Double(sorted.count - 1) / 86400  // Convert to days
        }

        let localPart = email.components(separatedBy: "@").first ?? ""
        let automatedPrefixes = ["noreply", "no-reply", "no_reply", "notifications", "alerts", "mailer", "auto"]
        let isAutomated = automatedPrefixes.contains { localPart.hasPrefix($0) }

        return SenderProfile(
            email: email,
            displayName: senderName,
            totalEmails: dates.count,
            firstSeen: first,
            lastSeen: last,
            averageFrequencyDays: avgFrequency,
            hasUnsubscribeOption: hasUnsubscribe,
            isLikelyAutomated: isAutomated
        )
    }
}
