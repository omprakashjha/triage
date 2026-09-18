import Foundation

/// A subscription worth considering ending, ranked by the mail it will stop ARRIVING.
///
/// The ranking metric is deliberately forward-looking. An obvious first instinct is to rank by how
/// much mail a sender has accumulated, but unsubscribing does not delete a single existing message —
/// it only stops the next ones. Measured on a real mailbox those two orderings disagree sharply: one
/// sender had 65 stored messages at 1.3 a month while another had 2 stored at 2.0 a month, so
/// historical volume would have put a dormant sender above a live one.
///
/// So `projectedYearlyVolume` is what sorts this list, and the historical count is shown only as
/// context.
public struct UnsubscribeCandidate: Identifiable, Sendable, Equatable {
    public var id: String { senderEmail }

    public let senderEmail: String
    public let displayName: String

    /// Messages stored from this sender. Context, not the ranking metric.
    public let storedVolume: Int
    /// Messages a year this sender is currently sending, from observed cadence.
    public let projectedYearlyVolume: Double
    /// How many of the stored messages advertised RFC 8058 one-click support.
    public let oneClickCount: Int
    /// Messages from this sender the app itself decided must be kept.
    public let mustKeepCount: Int

    /// What the model concluded about this sender, when it has an opinion.
    public let modelCategory: EmailCategory?
    /// Subject fragments the model said must survive.
    ///
    /// Surfaced because it is the one piece of information that makes an unsubscribe decision
    /// honest: ending a subscription also ends the parts of it that mattered. The model already
    /// produces these and nothing has ever displayed them.
    public let modelKeepSubjects: [String]

    public let firstSeen: Date
    public let lastSeen: Date
    /// Whether the user already tried to unsubscribe from this sender.
    public let alreadyAttempted: Bool

    public init(
        senderEmail: String,
        displayName: String,
        storedVolume: Int,
        projectedYearlyVolume: Double,
        oneClickCount: Int,
        mustKeepCount: Int,
        modelCategory: EmailCategory? = nil,
        modelKeepSubjects: [String] = [],
        firstSeen: Date,
        lastSeen: Date,
        alreadyAttempted: Bool = false
    ) {
        self.senderEmail = senderEmail.lowercased()
        self.displayName = displayName
        self.storedVolume = storedVolume
        self.projectedYearlyVolume = projectedYearlyVolume
        self.oneClickCount = oneClickCount
        self.mustKeepCount = mustKeepCount
        self.modelCategory = modelCategory
        self.modelKeepSubjects = modelKeepSubjects
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.alreadyAttempted = alreadyAttempted
    }

    /// Whether ending this subscription also ends mail the app decided to protect.
    ///
    /// Two independent sources count: the app's own must-keep classification, and the model's
    /// explicit list of subjects to preserve. Either one means the decision has a cost.
    public var hasCollateral: Bool {
        mustKeepCount > 0 || !modelKeepSubjects.isEmpty
    }

    /// Can be ended in one request, with no browser step.
    public var supportsOneClick: Bool { oneClickCount > 0 }

    /// Whether this sender has gone quiet, in which case unsubscribing achieves nothing.
    public func isDormant(asOf now: Date = Date(), quietDays: Int = 180) -> Bool {
        now.timeIntervalSince(lastSeen) > Double(quietDays) * 86_400
    }

    public enum Recommendation: String, Sendable {
        /// Live, disposable, nothing to lose.
        case unsubscribe
        /// Worth ending, but it will also stop mail that matters.
        case unsubscribeWithCollateral
        /// Stopped sending; ending it changes nothing.
        case dormant
        /// Too little traffic for the decision to be worth making.
        case notWorthIt

        public var displayName: String {
            switch self {
            case .unsubscribe: return "Unsubscribe"
            case .unsubscribeWithCollateral: return "Unsubscribe — but you lose some"
            case .dormant: return "Already quiet"
            case .notWorthIt: return "Barely writes"
            }
        }
    }

    /// The app's recommendation, ordered so the cheapest honest wins come first.
    ///
    /// The dormancy check precedes everything: a sender that has stopped writing cannot be stopped
    /// again, and offering it as an action would waste the user's attention on a no-op.
    public func recommendation(asOf now: Date = Date()) -> Recommendation {
        if isDormant(asOf: now) { return .dormant }
        // A rate needs something to be a rate OF. Measured on the real mailbox, one- and two-message
        // senders were being recommended outright and ranked above a sender with sixty-five, purely
        // because a short observation window flatters them. Below three observed messages there is no
        // cadence, only a coincidence.
        if storedVolume < 3 { return .notWorthIt }
        // Below roughly one mail a quarter, the decision costs more attention than the mail does.
        if projectedYearlyVolume < 4 { return .notWorthIt }
        if hasCollateral { return .unsubscribeWithCollateral }
        return .unsubscribe
    }
}
