import Foundation

/// One sender worth asking the user about, with everything needed to decide in one screen.
///
/// Exists because a review queue is the wrong unit of work. On a real mailbox 232 emails
/// needed review, but six senders accounted for 58% of them — so the user was being asked to
/// scroll 232 rows to make what were really six decisions. Ranking by how much mail a single
/// decision resolves turns the queue from a list into a short interview.
///
/// It also produces the measurement the app could not otherwise get. Corrections make poor
/// test data on their own: a correction FORCES an outcome, so scoring the pipeline against
/// one is circular — measured on a real mailbox it returned 100% category accuracy over 91
/// emails and told us nothing, because those were the 91 the corrections already governed.
/// A CONFIRMATION is different: the user agreeing with a verdict the model reached
/// independently is a genuine judgement, and the confirm-to-correct ratio across senders the
/// model actually decided is a real accuracy figure.
public struct TriageCandidate: Identifiable, Sendable, Equatable {
    public var id: String { senderEmail }

    public let senderEmail: String
    public let displayName: String

    /// How many of this sender's messages are awaiting a decision. This is the leverage: it
    /// is what one answer resolves.
    public let pendingCount: Int
    public let totalCount: Int

    /// What the app currently thinks, and why — shown so the user is confirming or
    /// overturning a stated position rather than answering from a blank slate.
    public let currentCategory: EmailCategory?
    public let currentTier: SafetyTier?
    public let currentReason: String?

    /// The model's own verdict, when it had one. Separate from `currentReason` because the
    /// pipeline may have overridden it, and the user should see what the model said even when
    /// something else won.
    public let modelCategory: EmailCategory?
    public let modelMustKeep: Bool?
    public let modelReason: String?
    public let modelWasUnsure: Bool

    /// A few subjects spread across the sender's history, so the decision is made on evidence
    /// rather than on the sender's address.
    public let sampleSubjects: [String]

    /// Where the provider filed this sender's mail, as a second opinion the user can weigh.
    public let providerLabelCounts: [String: Int]

    public let hasUnsubscribe: Bool

    public init(
        senderEmail: String,
        displayName: String,
        pendingCount: Int,
        totalCount: Int,
        currentCategory: EmailCategory?,
        currentTier: SafetyTier?,
        currentReason: String?,
        modelCategory: EmailCategory? = nil,
        modelMustKeep: Bool? = nil,
        modelReason: String? = nil,
        modelWasUnsure: Bool = false,
        sampleSubjects: [String] = [],
        providerLabelCounts: [String: Int] = [:],
        hasUnsubscribe: Bool = false
    ) {
        self.senderEmail = senderEmail
        self.displayName = displayName
        self.pendingCount = pendingCount
        self.totalCount = totalCount
        self.currentCategory = currentCategory
        self.currentTier = currentTier
        self.currentReason = currentReason
        self.modelCategory = modelCategory
        self.modelMustKeep = modelMustKeep
        self.modelReason = modelReason
        self.modelWasUnsure = modelWasUnsure
        self.sampleSubjects = sampleSubjects
        self.providerLabelCounts = providerLabelCounts
        self.hasUnsubscribe = hasUnsubscribe
    }

    /// Whether the provider's labels disagree about this sender, which usually means the
    /// right answer is a subject split rather than one verdict.
    public var looksMixed: Bool {
        providerLabelCounts.filter { $0.value > 0 }.count > 1
    }
}

/// Why a golden label exists, which decides whether it can measure anything.
///
/// A label promoted from a CORRECTION cannot measure the pipeline — the correction is the
/// highest-precedence input, so the pipeline is guaranteed to agree with it. A label from a
/// CONFIRMATION can: the model reached that verdict on its own and the user endorsed it, so
/// re-scoring later detects a regression, and the confirm-to-correct ratio is an accuracy
/// figure in its own right.
public enum LabelProvenance: String, Sendable {
    case correction
    case confirmation

    public var note: String {
        switch self {
        case .correction: return "From a user correction"
        case .confirmation: return "Confirmed the model's verdict"
        }
    }

    public init?(note: String?) {
        switch note {
        case LabelProvenance.correction.note: self = .correction
        case LabelProvenance.confirmation.note: self = .confirmation
        default: return nil
        }
    }
}
