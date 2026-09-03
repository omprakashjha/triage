import Foundation
import GRDB

/// Represents a connected email account (Gmail or Yahoo)
public struct EmailAccount: Identifiable, Hashable, Codable, FetchableRecord, PersistableRecord {
    public var id: Int64?
    public var email: String
    public var provider: EmailProvider
    public var displayName: String?
    public var lastSyncDate: Date?
    public var lastHistoryId: String?  // Gmail: for incremental sync
    public var isActive: Bool
    public var createdAt: Date

    public init(
        id: Int64? = nil,
        email: String,
        provider: EmailProvider,
        displayName: String? = nil,
        lastSyncDate: Date? = nil,
        lastHistoryId: String? = nil,
        isActive: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.email = email
        self.provider = provider
        self.displayName = displayName
        self.lastSyncDate = lastSyncDate
        self.lastHistoryId = lastHistoryId
        self.isActive = isActive
        self.createdAt = createdAt
    }

    // GRDB column definitions
    public enum Columns: String, ColumnExpression {
        case id, email, provider, displayName, lastSyncDate, lastHistoryId, isActive, createdAt
    }

    // GRDB: auto-increment id
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Supported email providers
public enum EmailProvider: String, Codable, Hashable, CaseIterable {
    case gmail
    case yahoo

    public var iconName: String {
        switch self {
        case .gmail: return "envelope.fill"
        case .yahoo: return "envelope.badge.fill"
        }
    }

    public var displayName: String {
        switch self {
        case .gmail: return "Gmail"
        case .yahoo: return "Yahoo Mail"
        }
    }
}
