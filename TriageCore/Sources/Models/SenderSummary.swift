import Foundation
import GRDB

/// One row per unique sender, aggregated across their mail.
///
/// This is the unit the triage UI works in. A 10,000-message inbox typically comes
/// from a few hundred senders, so deciding once per sender is tractable where
/// deciding once per message is not.
///
/// Aggregated in SQL rather than by loading every row into memory — the previous
/// in-memory version (`ContactDetector.buildSenderFrequencyMap`) capped out at
/// 10,000 emails and allocated one object per message.
public struct SenderSummary: Identifiable, Sendable, FetchableRecord {
    public var id: String { senderEmail }

    public let senderEmail: String
    /// Most recently seen display name for this address.
    public let displayName: String
    public let totalEmails: Int
    public let unreadEmails: Int
    public let firstSeen: Date
    public let lastSeen: Date
    /// True if ANY message from this sender carried a List-Unsubscribe header.
    public let hasUnsubscribeOption: Bool
    /// The category assigned to most of this sender's mail, if any.
    public let dominantCategory: EmailCategory?
    /// The strictest safety tier across this sender's mail. Protected wins, so a
    /// sender with any protected mail is never presented as bulk-actionable.
    public let strictestTier: SafetyTier?
    /// Whether this address is in the known-contacts list.
    public let isKnownContact: Bool

    public init(
        senderEmail: String,
        displayName: String,
        totalEmails: Int,
        unreadEmails: Int,
        firstSeen: Date,
        lastSeen: Date,
        hasUnsubscribeOption: Bool,
        dominantCategory: EmailCategory?,
        strictestTier: SafetyTier?,
        isKnownContact: Bool
    ) {
        self.senderEmail = senderEmail
        self.displayName = displayName
        self.totalEmails = totalEmails
        self.unreadEmails = unreadEmails
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.hasUnsubscribeOption = hasUnsubscribeOption
        self.dominantCategory = dominantCategory
        self.strictestTier = strictestTier
        self.isKnownContact = isKnownContact
    }

    public init(row: Row) {
        self.senderEmail = row["senderEmail"]
        self.displayName = row["displayName"] ?? row["senderEmail"]
        self.totalEmails = row["totalEmails"]
        self.unreadEmails = row["unreadEmails"] ?? 0
        self.firstSeen = row["firstSeen"]
        self.lastSeen = row["lastSeen"]
        self.hasUnsubscribeOption = (row["hasUnsubscribe"] as Int? ?? 0) > 0
        self.dominantCategory = (row["dominantCategory"] as String?).flatMap(EmailCategory.init(rawValue:))
        self.strictestTier = (row["strictestTier"] as String?).flatMap(SafetyTier.init(rawValue:))
        self.isKnownContact = (row["isKnownContact"] as Int? ?? 0) > 0
    }

    // MARK: - Derived signals

    /// Average days between messages from this sender. `nil` with fewer than 2 messages.
    public var averageIntervalDays: Double? {
        guard totalEmails > 1 else { return nil }
        let span = lastSeen.timeIntervalSince(firstSeen)
        guard span > 0 else { return nil }
        return span / Double(totalEmails - 1) / 86400
    }

    /// Days since this sender last wrote.
    public var daysSinceLastSeen: Int {
        Int(Date().timeIntervalSince(lastSeen) / 86400)
    }

    /// High volume plus an unsubscribe link is the signature of a subscription
    /// rather than a correspondent.
    public var looksLikeSubscription: Bool {
        if isKnownContact { return false }
        if hasUnsubscribeOption { return true }
        if let interval = averageIntervalDays, interval < 7, totalEmails > 5 { return true }
        return false
    }

    /// Never presented as safe to sweep: contacts and anything holding protected mail.
    public var isProtected: Bool {
        isKnownContact || strictestTier == .protected_
    }

    /// A sender the user has apparently stopped reading — high volume, all unread.
    public var isUnreadHeavy: Bool {
        totalEmails >= 5 && unreadEmails == totalEmails
    }
}
