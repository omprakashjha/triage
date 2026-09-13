import Foundation
import GRDB

/// A category the user fixed by hand.
///
/// The highest-precedence source in the whole pipeline: it outranks the rules and the
/// model, because it is the only source that is not guessing. Corrections earn that
/// standing by being cheap to give and expensive to ignore — a user who has to re-fix the
/// same sender every scan will stop trusting the app entirely.
///
/// Deliberately does four jobs from one gesture:
///
/// 1. Fixes the mail in front of the user.
/// 2. Pins the sender, so future mail from it is right without being asked again.
/// 3. Invalidates that sender's cached model verdict, so a stale wrong answer cannot
///    reassert itself on the next scan.
/// 4. Becomes an example in the model's prompt, so the model learns THIS mailbox — which
///    utilities, which bank, which language. This is the part that generalises: a
///    correction on one Dutch utility improves the answer for utilities the user has not
///    corrected yet.
///
/// It also doubles as a golden label, so accuracy becomes measurable from ordinary use
/// rather than needing a separate labelling chore.
public struct UserCorrection: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable,
    Identifiable
{
    public static let databaseTableName = "userCorrection"

    public var id: Int64?
    public var accountId: Int64
    public var senderEmail: String

    /// When set, this correction applies only to that sender's mail whose subject contains
    /// this text, case-insensitively.
    ///
    /// Needed because senders are not homogeneous. One real sender in the test mailbox
    /// sends 46 marketing messages and 58 travel receipts; a single correction for the
    /// whole sender is guaranteed to be wrong about one of those groups.
    public var subjectPattern: String?

    public var category: EmailCategory
    /// Whether losing this mail would matter. Drives the tier independently of category,
    /// because "promotional but I want it" is a real and common position.
    public var mustKeep: Bool

    /// What the app had said, kept so the correction is auditable and so evaluation can
    /// report what was actually wrong rather than only what is now right.
    public var previousCategory: EmailCategory?
    public var previousTier: SafetyTier?
    public var previousReason: String?

    public var correctedAt: Date

    public init(
        id: Int64? = nil,
        accountId: Int64,
        senderEmail: String,
        subjectPattern: String? = nil,
        category: EmailCategory,
        mustKeep: Bool,
        previousCategory: EmailCategory? = nil,
        previousTier: SafetyTier? = nil,
        previousReason: String? = nil,
        correctedAt: Date = Date()
    ) {
        self.id = id
        self.accountId = accountId
        self.senderEmail = senderEmail.lowercased()
        // Empty is treated as absent so the UI cannot accidentally create a rule that
        // matches every subject with the empty string.
        let trimmed = subjectPattern?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.subjectPattern = (trimmed?.isEmpty ?? true) ? nil : trimmed?.lowercased()
        self.category = category
        self.mustKeep = mustKeep
        self.previousCategory = previousCategory
        self.previousTier = previousTier
        self.previousReason = previousReason
        self.correctedAt = correctedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// The tier this correction implies.
    ///
    /// Determined by `mustKeep` ALONE. The category is a label; whether mail may be deleted
    /// is a separate decision, which is exactly why the sheet asks the two questions
    /// separately.
    ///
    /// This previously fell back to `category.isTypicallyDisposable`, so a user who
    /// categorised their broker's daily account statements as `notification` and
    /// explicitly unticked "never delete this automatically" got `.review` anyway — because
    /// notifications are not "typically" disposable. That is an instruction being overruled
    /// by a heuristic, which is the failure mode this whole type exists to end. 27 emails
    /// across three corrections were held in review by it.
    ///
    /// A correction may make mail auto-actionable, unlike a model verdict, which needs
    /// corroboration. The user is not a fallible classifier being trusted on its own
    /// judgement — they are the authority the app exists to serve, and declining to act on
    /// an explicit instruction is its own kind of failure.
    public var impliedTier: SafetyTier {
        mustKeep ? .protected_ : .safe
    }

    /// Whether this correction governs a given message.
    public func matches(senderEmail: String, subject: String) -> Bool {
        guard self.senderEmail == senderEmail.lowercased() else { return false }
        guard let subjectPattern else { return true }
        // Normalized on both sides, because a generated stem has had its punctuation replaced by
        // spaces and so is not a substring of the raw subject it came from. A raw `contains` here
        // meant a correction could silently fail to match its own email.
        return SubjectStem.pattern(subjectPattern, matches: subject)
    }

    /// How specific this correction is, so the narrowest matching one wins.
    public var specificity: Int {
        subjectPattern == nil ? 0 : 1
    }

    public enum Columns {
        static let id = Column("id")
        static let accountId = Column("accountId")
        static let senderEmail = Column("senderEmail")
        static let subjectPattern = Column("subjectPattern")
        static let category = Column("category")
        static let mustKeep = Column("mustKeep")
        static let correctedAt = Column("correctedAt")
    }
}
