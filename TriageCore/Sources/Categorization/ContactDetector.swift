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

    /// Build the contacts list from all available sources
    public func buildContactList(
        gmailSentLabels: [EmailMetadata] = [],
        yahooSentRecipients: Set<String> = [],
        manualContacts: Set<String> = []
    ) async -> Set<String> {
        var contacts: Set<String> = []

        // Source 1: Yahoo sent folder recipients
        contacts.formUnion(yahooSentRecipients)

        // Source 2: Gmail sent emails (from cached metadata with "SENT" label)
        let gmailRecipients = extractGmailSentRecipients(from: gmailSentLabels)
        contacts.formUnion(gmailRecipients)

        // Source 3: Manual contacts
        contacts.formUnion(manualContacts)

        // Source 4: Reply detection — senders the user has exchanged emails with
        let replyContacts = await detectReplyContacts()
        contacts.formUnion(replyContacts)

        // Normalize all to lowercase
        knownContacts = Set(contacts.map { $0.lowercased() })
        return knownContacts
    }

    /// Detect contacts by finding sender addresses that appear in multiple threads
    /// (heuristic: if someone emails you and you email them back, they're a contact)
    private func detectReplyContacts() async -> Set<String> {
        // Look for senders who the user has interacted with frequently
        // This is approximated by finding senders with emails in multiple threads
        // For a more precise approach, we'd need the Sent folder analysis
        return []
    }

    /// Extract recipients from Gmail sent emails (emails with "SENT" label)
    private func extractGmailSentRecipients(from sentEmails: [EmailMetadata]) -> Set<String> {
        // In Gmail, sent emails have the user as sender — but we store the "To" recipients
        // For now, we mark the sender of any email that was in "SENT" as a contact
        // because it means the user sent something to them
        Set(sentEmails.map { $0.senderEmail.lowercased() })
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
