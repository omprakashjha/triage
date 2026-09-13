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

    /// When set, this label applies only to that sender's mail whose subject contains this
    /// text, case-insensitively.
    ///
    /// Added because sender-level labelling could not represent what the user actually
    /// produced. Of 29 real corrections, 26 were subject-scoped — the user was splitting
    /// mixed senders, which is exactly the hard case worth measuring — so promoting only
    /// whole-sender corrections yielded 3 labels and a precision figure computed from 3
    /// labels is not a measurement.
    ///
    /// The original comment here claimed sender-level was sufficient because "the top ~100
    /// senders cover most of a large mailbox". True of VOLUME, wrong about DIFFICULTY: the
    /// senders that need measuring are precisely the ones a single label cannot describe.
    public var subjectPattern: String?
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
        subjectPattern: String? = nil,
        expectedCategory: EmailCategory,
        disposition: Disposition,
        note: String? = nil,
        labelledAt: Date = Date()
    ) {
        self.id = id
        self.accountId = accountId
        self.senderEmail = senderEmail.lowercased()
        // Empty is treated as absent, so a blank field cannot create a label that matches
        // every subject via the empty string.
        let trimmed = subjectPattern?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.subjectPattern = (trimmed?.isEmpty ?? true) ? nil : trimmed?.lowercased()
        self.expectedCategory = expectedCategory
        self.disposition = disposition
        self.note = note
        self.labelledAt = labelledAt
    }

    /// Whether this label governs a given message.
    public func matches(senderEmail: String, subject: String) -> Bool {
        guard self.senderEmail == senderEmail.lowercased() else { return false }
        guard let subjectPattern else { return true }
        // Same normalization as UserCorrection, and for the same reason: labels are promoted FROM
        // corrections, so a label carrying a generated stem must match the mail its correction
        // matched. Leaving these two disagreeing would silently understate measured accuracy.
        return SubjectStem.pattern(subjectPattern, matches: subject)
    }

    /// How specific this label is, so the narrowest matching one is scored against.
    public var specificity: Int {
        subjectPattern == nil ? 0 : 1
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
