import Foundation

/// What the model is asked to judge: one SENDER, not one email.
///
/// Classifying senders rather than messages is the decision that makes this
/// affordable. A 10,000-message mailbox has a few hundred senders, so this is roughly
/// a 30x reduction in calls — and a better signal, because the model sees the pattern
/// across a sender's mail instead of guessing from a single subject line.
public struct SenderClassificationRequest: Sendable, Equatable {
    public let senderEmail: String
    public let displayName: String
    /// A handful of that sender's subjects, newest first.
    public let sampleSubjects: [String]
    public let totalEmails: Int
    public let hasUnsubscribe: Bool
    /// Average days between messages, when known.
    public let averageIntervalDays: Double?

    public init(
        senderEmail: String,
        displayName: String,
        sampleSubjects: [String],
        totalEmails: Int,
        hasUnsubscribe: Bool,
        averageIntervalDays: Double? = nil
    ) {
        self.senderEmail = senderEmail
        self.displayName = displayName
        self.sampleSubjects = sampleSubjects
        self.totalEmails = totalEmails
        self.hasUnsubscribe = hasUnsubscribe
        self.averageIntervalDays = averageIntervalDays
    }
}

/// The model's judgement about one sender.
public struct SenderVerdict: Sendable, Codable, Equatable {
    public let senderEmail: String
    public let category: EmailCategory
    /// Whether losing this sender's mail would matter. Drives the safety tier.
    public let mustKeep: Bool
    /// Whether this looks like a real person rather than a system or a list.
    public let isRealPerson: Bool
    public let confidence: Double
    public let reason: String

    public init(
        senderEmail: String,
        category: EmailCategory,
        mustKeep: Bool,
        isRealPerson: Bool,
        confidence: Double,
        reason: String
    ) {
        self.senderEmail = senderEmail.lowercased()
        self.category = category
        self.mustKeep = mustKeep
        self.isRealPerson = isRealPerson
        self.confidence = confidence
        self.reason = reason
    }

    /// The tier this verdict implies on its own.
    ///
    /// A real person, or mail the model says must be kept, is never auto-actionable.
    public var impliedTier: SafetyTier {
        if isRealPerson { return .protected_ }
        if mustKeep { return .review }
        return .safe
    }
}

/// A provider that can classify senders.
///
/// Deliberately provider-neutral: the engine and its safety rules must not depend on
/// which service answers. Bedrock, a direct HTTP API, or an on-device model all sit
/// behind this.
public protocol LLMTransport: Sendable {
    /// Identifies the model. Part of the cache key, so switching models re-classifies
    /// rather than silently reusing another model's verdicts.
    var modelId: String { get }
    /// Bumped whenever the prompt changes, for the same reason.
    var promptVersion: String { get }

    func classify(senders: [SenderClassificationRequest]) async throws -> [SenderVerdict]
}

/// The prompt and output contract, kept in one reviewable place.
///
/// Structured output is forced via a schema rather than parsed out of prose: a
/// classifier whose output shape can drift is a classifier that will eventually
/// mis-assign a tier.
public enum SenderClassificationPrompt {
    public static let version = "sender.v1"

    public static let system = """
        You classify EMAIL SENDERS for an inbox cleanup tool. For each sender you are \
        given their address, display name, how many messages they sent, whether their \
        mail carries an unsubscribe header, how often they write, and a sample of \
        subject lines.

        Assign each sender exactly one category:
        - newsletter: editorial or digest content the user subscribed to
        - promotion: marketing, offers, sales
        - notification: automated status, alerts, system messages
        - transactional: receipts, invoices, orders, statements, bookings, tickets
        - social: social networks and community platforms
        - personal: a real human writing to this person
        - unknown: genuinely cannot tell

        Then answer two safety questions independently of the category:
        - mustKeep: would losing this sender's mail cost the user something they cannot \
        recover? Receipts, invoices, bookings, legal and medical correspondence, \
        account-security notices and anything from a real person are mustKeep. A \
        marketing email is not.
        - isRealPerson: is this an individual human rather than a system, a list, or a \
        no-reply address?

        Judge on the evidence given. Do not invent facts about the sender. When the \
        samples are ambiguous, say so with a low confidence and prefer mustKeep=true — \
        the cost of wrongly keeping a promotion is one extra row in a list, and the \
        cost of wrongly discarding a receipt is permanent.

        A sender can be promotional AND mustKeep: large retailers send offers and order \
        confirmations from the same address.

        confidence is your own probability that the category is correct, from 0 to 1.
        reason is one short clause naming the evidence you used, for the user to read.
        """

    /// JSON Schema for the forced tool-use / structured-output call.
    ///
    /// Typed as `JSONValue` rather than `[String: Any]` so it stays `Sendable` and can
    /// be bridged to the SDK's document type without casting.
    public static var outputSchema: JSONValue {
        .object([
            "type": "object",
            "properties": .object([
                "verdicts": .object([
                    "type": "array",
                    "items": .object([
                        "type": "object",
                        "properties": .object([
                            "senderEmail": .object(["type": "string"]),
                            "category": .object([
                                "type": "string",
                                "enum": .array(EmailCategory.allCases.map { .string($0.rawValue) }),
                            ]),
                            "mustKeep": .object(["type": "boolean"]),
                            "isRealPerson": .object(["type": "boolean"]),
                            "confidence": .object([
                                "type": "number", "minimum": 0, "maximum": 1,
                            ]),
                            "reason": .object(["type": "string", "maxLength": 160]),
                        ]),
                        "required": .array([
                            "senderEmail", "category", "mustKeep",
                            "isRealPerson", "confidence", "reason",
                        ]),
                    ]),
                ])
            ]),
            "required": .array(["verdicts"]),
        ])
    }

    public static let toolName = "record_sender_verdicts"

    public static let toolDescription =
        "Record one classification verdict per sender that was provided."

    /// Parse the model's tool payload into verdicts.
    ///
    /// Tolerant about what it drops and strict about what it keeps: a malformed entry is
    /// skipped rather than defaulted, because a verdict with a silently invented field
    /// would feed the tier decision. Confidence is clamped, and an unrecognised category
    /// falls back to `.unknown` with `mustKeep` forced true — an unparseable verdict must
    /// never make mail more deletable.
    public static func parseVerdicts(from payload: JSONValue) -> [SenderVerdict] {
        guard let entries = payload["verdicts"]?.arrayValue else { return [] }

        return entries.compactMap { entry -> SenderVerdict? in
            guard let sender = entry["senderEmail"]?.stringValue, sender.contains("@") else {
                return nil
            }

            let rawCategory = entry["category"]?.stringValue ?? ""
            let parsedCategory = EmailCategory(rawValue: rawCategory)
            let category = parsedCategory ?? .unknown

            // An unparseable category means we do not actually know what this is.
            let mustKeep = (entry["mustKeep"]?.boolValue ?? true) || parsedCategory == nil
            let isRealPerson = entry["isRealPerson"]?.boolValue ?? false

            let confidence = min(max(entry["confidence"]?.doubleValue ?? 0, 0), 1)
            let reason = entry["reason"]?.stringValue ?? "no reason given"

            return SenderVerdict(
                senderEmail: sender,
                category: category,
                mustKeep: mustKeep,
                isRealPerson: isRealPerson,
                confidence: parsedCategory == nil ? min(confidence, 0.3) : confidence,
                reason: reason
            )
        }
    }

    /// Render the user-message payload for a batch.
    ///
    /// Only sender, subjects and counts are sent. Message bodies are never included —
    /// the app does not even fetch them, so the maximum possible egress is a subject
    /// line and a sender address.
    public static func userMessage(for senders: [SenderClassificationRequest]) -> String {
        var lines: [String] = ["Classify these senders:", ""]
        for sender in senders {
            lines.append("- address: \(sender.senderEmail)")
            lines.append("  name: \(sender.displayName)")
            lines.append("  messages: \(sender.totalEmails)")
            lines.append("  unsubscribe_header: \(sender.hasUnsubscribe)")
            if let interval = sender.averageIntervalDays {
                lines.append(String(format: "  avg_days_between: %.1f", interval))
            }
            lines.append("  subjects:")
            for subject in sender.sampleSubjects.prefix(5) {
                lines.append("    - \(subject)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
