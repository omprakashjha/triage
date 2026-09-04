import Foundation
import GRDB

/// An address the user demonstrably corresponds with.
///
/// Mail from a known contact is categorized `.personal` / `.protected_` and is never
/// auto-actioned. This record exists so contact detection survives across scans:
/// rebuilding it needs network calls, and an empty contact set silently disables the
/// only rule that produces the protected tier.
public struct KnownContact: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable {
    public var id: Int64?
    public var accountId: Int64
    /// Always stored lowercased — matching is case-insensitive.
    public var email: String
    public var source: ContactSource
    /// How many times this address was seen in the evidence used to detect it.
    /// Higher counts mean a stronger correspondent relationship.
    public var occurrences: Int
    public var addedAt: Date

    public init(
        id: Int64? = nil,
        accountId: Int64,
        email: String,
        source: ContactSource,
        occurrences: Int = 1,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.accountId = accountId
        self.email = email.lowercased()
        self.source = source
        self.occurrences = occurrences
        self.addedAt = addedAt
    }

    public enum Columns: String, ColumnExpression {
        case id, accountId, email, source, occurrences, addedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Where a contact came from. Recorded so the user can tell a detected contact from
/// one they pinned by hand, and so a re-detection does not clobber manual entries.
public enum ContactSource: String, Codable, CaseIterable, Sendable {
    /// Extracted from the To/Cc of the user's own sent mail — the strongest signal.
    case sentMail
    /// Gmail itself classified the thread as personal (CATEGORY_PERSONAL label).
    case gmailPersonalLabel
    /// The user pinned this address explicitly. Never removed by re-detection.
    case manual

    public var displayName: String {
        switch self {
        case .sentMail: return "You've emailed them"
        case .gmailPersonalLabel: return "Gmail marks as personal"
        case .manual: return "Pinned by you"
        }
    }

    /// Manual entries are authoritative and survive re-detection.
    public var isUserAuthored: Bool { self == .manual }
}
