import Foundation
import GRDB

/// Core email metadata record cached locally for categorization and action planning
public struct EmailMetadata: Identifiable, Codable, FetchableRecord, PersistableRecord {
    public var id: Int64?
    public var accountId: Int64
    public var messageId: String       // Provider's message ID (Gmail ID or IMAP UID)
    public var threadId: String?       // Gmail thread ID
    public var sender: String          // Display name of sender
    public var senderEmail: String     // Parsed email address
    public var subject: String
    public var date: Date
    public var snippet: String?        // Short preview text

    // Headers relevant for categorization
    public var hasListUnsubscribe: Bool
    public var listUnsubscribeHeader: String?  // Raw header value for unsubscribe automation
    public var replyTo: String?

    // Gmail-specific
    public var labels: [String]?       // Gmail label IDs
    public var isUnread: Bool

    // Categorization
    public var category: EmailCategory?
    public var safetyTier: SafetyTier?
    public var categoryConfidence: Double?
    /// Human-readable justification from the engine, e.g. "Mixed sender (amazon.com)
    /// with a transactional subject". Shown in the UI so a user can judge a decision.
    public var categoryReason: String?

    // Action tracking
    public var actionTaken: EmailAction?
    public var actionDate: Date?
    /// When this action was actually carried out against the provider.
    /// `nil` while the action is only marked locally (pending), set once executed.
    /// Undo clears it along with `actionTaken`.
    public var actionExecutedAt: Date?

    /// Marked by the user but not yet sent to the provider.
    public var isPendingAction: Bool { actionTaken != nil && actionExecutedAt == nil }

    /// Already carried out against the provider — excluded from the working views
    /// but retained so the action stays undoable.
    public var isExecuted: Bool { actionExecutedAt != nil }

    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64? = nil,
        accountId: Int64,
        messageId: String,
        threadId: String? = nil,
        sender: String,
        senderEmail: String,
        subject: String,
        date: Date,
        snippet: String? = nil,
        hasListUnsubscribe: Bool = false,
        listUnsubscribeHeader: String? = nil,
        replyTo: String? = nil,
        labels: [String]? = nil,
        isUnread: Bool = true,
        category: EmailCategory? = nil,
        safetyTier: SafetyTier? = nil,
        categoryConfidence: Double? = nil,
        categoryReason: String? = nil,
        actionTaken: EmailAction? = nil,
        actionDate: Date? = nil,
        actionExecutedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.accountId = accountId
        self.messageId = messageId
        self.threadId = threadId
        self.sender = sender
        self.senderEmail = senderEmail
        self.subject = subject
        self.date = date
        self.snippet = snippet
        self.hasListUnsubscribe = hasListUnsubscribe
        self.listUnsubscribeHeader = listUnsubscribeHeader
        self.replyTo = replyTo
        self.labels = labels
        self.isUnread = isUnread
        self.category = category
        self.safetyTier = safetyTier
        self.categoryConfidence = categoryConfidence
        self.categoryReason = categoryReason
        self.actionTaken = actionTaken
        self.actionDate = actionDate
        self.actionExecutedAt = actionExecutedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // GRDB column definitions
    public enum Columns: String, ColumnExpression {
        case id, accountId, messageId, threadId, sender, senderEmail
        case subject, date, snippet
        case hasListUnsubscribe, listUnsubscribeHeader, replyTo
        case labels, isUnread
        case category, safetyTier, categoryConfidence, categoryReason
        case actionTaken, actionDate, actionExecutedAt
        case createdAt, updatedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Enums

/// Email categories assigned by the rule engine or AI
public enum EmailCategory: String, Codable, CaseIterable, Sendable {
    case newsletter
    case promotion
    case notification
    case transactional
    case social
    case personal
    case unknown

    public var displayName: String {
        rawValue.capitalized
    }

    public var iconName: String {
        switch self {
        case .newsletter: return "newspaper"
        case .promotion: return "tag"
        case .notification: return "bell"
        case .transactional: return "creditcard"
        case .social: return "person.2"
        case .personal: return "person"
        case .unknown: return "questionmark.circle"
        }
    }
}

/// Safety tier determines how an email can be acted upon
public enum SafetyTier: String, Codable, CaseIterable, Sendable {
    case safe       // Auto-actionable (old promos, newsletters)
    case review     // Needs user approval before action
    case protected_ // Never auto-deleted (contacts, replies, important)

    // Using protected_ to avoid Swift keyword conflict
    public var displayName: String {
        switch self {
        case .safe: return "Safe"
        case .review: return "Review"
        case .protected_: return "Protected"
        }
    }
}

/// Actions that can be taken on emails
public enum EmailAction: String, Codable, CaseIterable, Sendable {
    case archived
    case deleted
    case labeled
    case unsubscribed
    case skipped
}
