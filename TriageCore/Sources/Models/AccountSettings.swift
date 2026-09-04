import Foundation

/// What subset of the mailbox a scan covers.
///
/// The scan was previously hardcoded to `is:unread`, which meant every statistic,
/// category count and plan described only unread mail — invisible to the user, and
/// misleading, since for most bloated mailboxes the bulk is read-but-never-deleted.
public enum ScanScope: String, Codable, CaseIterable, Sendable {
    case unreadOnly
    case inbox
    case olderThanOneYear
    case allMail

    /// The Gmail search query for this scope.
    public var gmailQuery: String {
        switch self {
        case .unreadOnly: return "is:unread"
        case .inbox: return "in:inbox"
        case .olderThanOneYear: return "older_than:1y"
        case .allMail: return ""
        }
    }

    public var displayName: String {
        switch self {
        case .unreadOnly: return "Unread only"
        case .inbox: return "Everything in Inbox"
        case .olderThanOneYear: return "Older than 1 year"
        case .allMail: return "All mail"
        }
    }

    public var explanation: String {
        switch self {
        case .unreadOnly:
            return "Fastest. Misses mail you've read but never deleted, which is usually most of it."
        case .inbox:
            return "Everything currently in your inbox, read or not."
        case .olderThanOneYear:
            return "Old mail only — the safest large cleanup, since nothing recent is touched."
        case .allMail:
            return "Includes archived mail. Slowest scan and the largest result set."
        }
    }

    /// Whether a message fetched by the History API belongs to this scope.
    ///
    /// Incremental sync pulls every added message regardless of query, so without this
    /// the local database drifts to contain mail a full sync would never have added.
    public func includes(labelIds: [String]?, isUnread: Bool, date: Date, now: Date = Date()) -> Bool {
        switch self {
        case .unreadOnly:
            return isUnread
        case .inbox:
            return labelIds?.contains("INBOX") ?? false
        case .olderThanOneYear:
            return date < now.addingTimeInterval(-365 * 86400)
        case .allMail:
            return true
        }
    }
}

/// Cloud categorization configuration.
///
/// Off by default. The app is otherwise entirely local — enabling this is the one
/// choice that sends anything off the machine, so it is opt-in and never implicit.
public struct AIConfig: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    /// Empty means the transport's own default.
    public var modelId: String
    /// Empty means "use the region from the AWS profile". Setting this explicitly
    /// OVERRIDES the profile, which is rarely what someone wants.
    public var region: String

    public init(isEnabled: Bool = false, modelId: String = "", region: String = "") {
        self.isEnabled = isEnabled
        self.modelId = modelId
        self.region = region
    }

    /// What actually leaves the machine when this is on. Shown to the user verbatim.
    public static let egressDescription = """
        Sender address, display name, message counts, how often they write, and up to \
        five subject lines per sender. Message bodies are never sent — the app does not \
        fetch them at all. Only senders the local rules could not resolve are sent, and \
        each sender is sent at most once per model and prompt version.
        """
}

/// Per-account persisted configuration.
public struct AccountSettings: Sendable, Equatable {
    public let accountId: Int64
    public var actionRules: ActionRules
    public var scanScope: ScanScope
    public var aiConfig: AIConfig

    public init(
        accountId: Int64,
        actionRules: ActionRules = .default,
        scanScope: ScanScope = .unreadOnly,
        aiConfig: AIConfig = AIConfig()
    ) {
        self.accountId = accountId
        self.actionRules = actionRules
        self.scanScope = scanScope
        self.aiConfig = aiConfig
    }
}
