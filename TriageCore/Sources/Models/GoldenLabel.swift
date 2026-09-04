import Foundation
import GRDB

/// A human judgement about a sender, used as ground truth for measuring the engine.
///
/// Labelled at SENDER level rather than per-message: the top ~100 senders typically
/// cover 80%+ of a large mailbox, which turns "label a golden set" from a month of
/// work into an evening of it.
///
/// The engine's own tests assert that specific inputs produce specific categories,
/// where the expected values were written by whoever wrote the rules. That measures
/// self-consistency, not correctness. These labels are the independent reference.
public struct GoldenLabel: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable {
    public var id: Int64?
    public var accountId: Int64
    public var senderEmail: String
    /// What this sender's mail actually is.
    public var expectedCategory: EmailCategory
    /// The judgement that actually matters for safety.
    public var disposition: Disposition
    public var note: String?
    public var labelledAt: Date

    public init(
        id: Int64? = nil,
        accountId: Int64,
        senderEmail: String,
        expectedCategory: EmailCategory,
        disposition: Disposition,
        note: String? = nil,
        labelledAt: Date = Date()
    ) {
        self.id = id
        self.accountId = accountId
        self.senderEmail = senderEmail.lowercased()
        self.expectedCategory = expectedCategory
        self.disposition = disposition
        self.note = note
        self.labelledAt = labelledAt
    }

    public enum Columns: String, ColumnExpression {
        case id, accountId, senderEmail, expectedCategory, disposition, note, labelledAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Whether losing this sender's mail would matter.
///
/// This is the axis the app's safety rests on, and it is deliberately separate from
/// category: a promotional email from an airline can still be a booking confirmation,
/// and a "notification" can be the only record of a password change.
public enum Disposition: String, Codable, CaseIterable, Sendable {
    /// Deleting this sender's mail costs nothing.
    case disposable
    /// This sender's mail must survive — deleting it is a real loss.
    case mustKeep

    public var displayName: String {
        switch self {
        case .disposable: return "Safe to delete"
        case .mustKeep: return "Must keep"
        }
    }

    public var explanation: String {
        switch self {
        case .disposable: return "Losing this changes nothing."
        case .mustKeep: return "Losing this would matter — receipts, records, real people."
        }
    }
}

/// A portable snapshot of the golden set, so it can live in the repo as a test fixture
/// rather than only in one machine's database.
public struct GoldenSetExport: Codable, Sendable {
    public let exportedAt: Date
    public let accountEmail: String
    public let labels: [ExportedLabel]

    public struct ExportedLabel: Codable, Sendable {
        public let senderEmail: String
        public let expectedCategory: String
        public let disposition: String
        public let note: String?
    }

    public init(exportedAt: Date = Date(), accountEmail: String, labels: [ExportedLabel]) {
        self.exportedAt = exportedAt
        self.accountEmail = accountEmail
        self.labels = labels
    }
}
