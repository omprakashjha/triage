import Foundation
import GRDB

/// Log of all actions taken, enabling undo functionality
public struct ActionLog: Identifiable, Codable, FetchableRecord, PersistableRecord {
    public var id: Int64?
    public var accountId: Int64
    public var action: EmailAction
    public var messageIds: [String]    // Provider message IDs affected
    public var messageCount: Int
    public var isReversible: Bool
    public var isReversed: Bool
    public var executedAt: Date
    public var reversedAt: Date?
    public var description: String     // Human-readable description

    public init(
        id: Int64? = nil,
        accountId: Int64,
        action: EmailAction,
        messageIds: [String],
        messageCount: Int,
        isReversible: Bool = true,
        isReversed: Bool = false,
        executedAt: Date = Date(),
        reversedAt: Date? = nil,
        description: String
    ) {
        self.id = id
        self.accountId = accountId
        self.action = action
        self.messageIds = messageIds
        self.messageCount = messageCount
        self.isReversible = isReversible
        self.isReversed = isReversed
        self.executedAt = executedAt
        self.reversedAt = reversedAt
        self.description = description
    }

    public enum Columns: String, ColumnExpression {
        case id, accountId, action, messageIds, messageCount
        case isReversible, isReversed, executedAt, reversedAt, description
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
