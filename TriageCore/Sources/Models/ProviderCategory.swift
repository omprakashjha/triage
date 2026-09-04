import Foundation

/// The mail provider's own classification of a message.
///
/// A second, independent opinion — and on a non-English mailbox a better-informed one
/// than this app's rules, which are hand-written English keyword and domain lists. Gmail
/// applies exactly one `CATEGORY_*` label per message and does so in any language.
///
/// Used two ways, both language-independent:
///
/// - As a **veto**. When the provider says a message is an Update or Personal and the
///   rules called it promotional, the rules are probably wrong: those are the buckets
///   receipts, statements and confirmations land in. That disagreement forces review
///   rather than being resolved by guessing.
/// - As **corroboration**. When the provider and the rules independently agree the mail
///   is promotional or social, that is genuinely strong evidence, and the mail can be
///   auto-actioned without a model call.
public enum ProviderCategory: String, Sendable, Codable, Equatable {
    case promotions
    case social
    case updates
    case forums
    case personal

    public init?(gmailLabel: String) {
        switch gmailLabel.uppercased() {
        case "CATEGORY_PROMOTIONS": self = .promotions
        case "CATEGORY_SOCIAL": self = .social
        case "CATEGORY_UPDATES": self = .updates
        case "CATEGORY_FORUMS": self = .forums
        case "CATEGORY_PERSONAL": self = .personal
        default: return nil
        }
    }

    /// Whether the provider considers this mail bulk marketing.
    ///
    /// Note that `.updates` is deliberately NOT included. Gmail's Updates bucket is where
    /// bills, receipts, order confirmations and account notices go — the mail that most
    /// needs keeping. Treating it as disposable is the exact mistake that put an annual
    /// water bill in the auto-actionable tier.
    public var isBulkMarketing: Bool {
        self == .promotions
    }

    /// Whether the provider's placement argues against ever auto-actioning this mail.
    public var arguesForKeeping: Bool {
        self == .updates || self == .personal
    }

    /// The category this provider label most closely corresponds to, for reporting.
    public var likelyCategory: EmailCategory {
        switch self {
        case .promotions: return .promotion
        case .social: return .social
        case .updates: return .transactional
        case .forums: return .newsletter
        case .personal: return .personal
        }
    }

    public var displayName: String {
        switch self {
        case .promotions: return "Promotions"
        case .social: return "Social"
        case .updates: return "Updates"
        case .forums: return "Forums"
        case .personal: return "Personal"
        }
    }
}
