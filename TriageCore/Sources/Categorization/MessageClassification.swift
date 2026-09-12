import Foundation

/// One message put to the model on its own.
///
/// Exists because sender-level classification has a hard ceiling that a real mailbox walked
/// straight into. Asked to describe a rail operator by subject patterns, the model produced
/// `["dagje uit", "eropuit", "voordelig", "acties"]` — reasonable rules that matched a handful
/// of 54 messages, because that sender writes fresh marketing copy every week. "Maak kans op
/// een jaar gratis treinen!" is unmistakably promotional and matches no pattern anyone would
/// have written in advance. No pattern set generalises over editorial variety; reading the
/// message does.
public struct MessageClassificationRequest: Sendable, Equatable {
    public let messageId: String
    public let senderEmail: String
    public let displayName: String
    public let subject: String
    /// A short body preview, when the user has allowed sending them.
    public let snippet: String?

    /// How old the message is, in days.
    ///
    /// Load-bearing rather than decorative. The same mailbox held "7 januari minder treinen
    /// door winters weer" — a train disruption notice that was important the day before the
    /// date and is worthless history now. Age is what separates those two states, and a
    /// sender-level verdict cannot see it at all.
    public let ageDays: Int

    /// Where the provider filed this specific message.
    public let providerCategory: ProviderCategory?

    /// What the sender-level pass concluded, so the model is refining a view rather than
    /// starting cold — and can disagree with it on this particular message.
    public let senderVerdictSummary: String?

    public let hasUnsubscribe: Bool

    public init(
        messageId: String,
        senderEmail: String,
        displayName: String,
        subject: String,
        snippet: String? = nil,
        ageDays: Int,
        providerCategory: ProviderCategory? = nil,
        senderVerdictSummary: String? = nil,
        hasUnsubscribe: Bool = false
    ) {
        self.messageId = messageId
        self.senderEmail = senderEmail
        self.displayName = displayName
        self.subject = subject
        self.snippet = snippet
        self.ageDays = ageDays
        self.providerCategory = providerCategory
        self.senderVerdictSummary = senderVerdictSummary
        self.hasUnsubscribe = hasUnsubscribe
    }
}

/// The model's judgement on one message.
public struct MessageVerdict: Sendable, Codable, Equatable {
    public let messageId: String
    public let category: EmailCategory
    public let mustKeep: Bool
    public let confidence: Double
    public let reason: String
    /// Still permitted at message level. A message can be genuinely unreadable — a bare
    /// "Bericht van Wouter Koolmees" with no preview — and guessing at it is worse than
    /// saying so.
    public let isUnsure: Bool

    public init(
        messageId: String,
        category: EmailCategory,
        mustKeep: Bool,
        confidence: Double,
        reason: String,
        isUnsure: Bool = false
    ) {
        self.messageId = messageId
        self.category = category
        self.mustKeep = mustKeep
        self.confidence = confidence
        self.reason = reason
        self.isUnsure = isUnsure
    }

    /// The tier this verdict implies. Same semantics as a sender verdict: a decision to keep
    /// is settled, and only an abstention is pending.
    public var impliedTier: SafetyTier {
        if isUnsure { return .review }
        if mustKeep { return .protected_ }
        return .safe
    }
}

/// The message-level prompt and output contract.
public enum MessageClassificationPrompt {
    public static let version = "message.v1"

    public static let system = """
        You classify INDIVIDUAL EMAILS for an inbox cleanup tool. Each one has already been \
        looked at by a pass that judged its SENDER, and that pass could not decide this \
        message. You are reading it directly.

        Assign each message exactly one category:
        - newsletter: editorial or digest content the user subscribed to
        - promotion: marketing, offers, sales, competitions, prize draws, events, surveys \
        about products, brand storytelling
        - notification: automated status, alerts, system or service messages
        - transactional: receipts, invoices, orders, statements, bookings, tickets
        - social: social networks and community platforms
        - personal: a real human writing to this person
        - unknown: genuinely cannot tell

        Then answer, independently of the category:
        - mustKeep: would losing THIS message cost the user something they cannot recover? \
        Receipts, invoices, bookings, tickets they may still travel on, legal, medical, tax \
        and account-security messages are mustKeep. Marketing is not.

        THE MAIL IS OFTEN NOT IN ENGLISH. Judge by meaning. A Dutch prize draw ("maak kans \
        op"), a discount campaign ("profiteer", "acties", "korting"), a seasonal campaign \
        ("de zomer is in aantocht") and a brand competition are all promotion. A Dutch \
        invoice ("factuur", "jaarafrekening") is transactional and mustKeep.

        AGE MATTERS, and it is why you are given it. A service message about a specific past \
        date has no remaining value: a notice that fewer trains run on 7 January, read in \
        September, cannot be acted on and is not worth keeping. Treat an expired \
        time-specific operational notice as NOT mustKeep, however important it was on the \
        day. Apply this only when the message is tied to a date that has passed — an \
        undated policy change, a receipt or a statement does not expire this way.

        SAY WHEN YOU CANNOT TELL. Set unsure=true for a message whose subject is opaque and \
        which has no preview to read. An honest abstention sends one message to the user; a \
        confident wrong answer can destroy it.

        confidence is your probability that the category is right, 0 to 1.
        reason is one short clause naming what in the message decided it, for the user to read.
        """

    private static var categoryProperty: JSONValue {
        .object([
            "type": "string",
            "enum": .array(EmailCategory.allCases.map { .string($0.rawValue) }),
        ])
    }

    private static var verdictProperties: JSONValue {
        .object([
            "messageId": .object(["type": "string"]),
            "category": categoryProperty,
            "mustKeep": .object(["type": "boolean"]),
            "confidence": .object(["type": "number", "minimum": 0, "maximum": 1]),
            "reason": .object(["type": "string", "maxLength": 160]),
            "unsure": .object(["type": "boolean"]),
        ])
    }

    private static var verdictItem: JSONValue {
        .object([
            "type": "object",
            "properties": verdictProperties,
            "required": .array([
                "messageId", "category", "mustKeep", "confidence", "reason",
            ]),
        ])
    }

    public static var outputSchema: JSONValue {
        .object([
            "type": "object",
            "properties": .object([
                "verdicts": .object(["type": "array", "items": verdictItem])
            ]),
            "required": .array(["verdicts"]),
        ])
    }

    public static let toolName = "record_message_verdicts"
    public static let toolDescription =
        "Record one classification verdict per message that was provided."

    /// The full system prompt, including anything learned from the user.
    public static func systemPrompt(corrections: [CorrectionExample] = []) -> String {
        let base: String = system
        return base + SenderClassificationPrompt.correctionsSection(corrections)
    }

    /// Parse the model's payload.
    ///
    /// Same posture as the sender parser: tolerant about what it drops, strict about what it
    /// keeps, and a malformed entry never becomes a verdict that could delete mail.
    public static func parseVerdicts(from payload: JSONValue) -> [MessageVerdict] {
        guard let entries = payload["verdicts"]?.arrayValue else { return [] }

        return entries.compactMap { entry -> MessageVerdict? in
            guard let id = entry["messageId"]?.stringValue, !id.isEmpty else { return nil }

            let rawCategory = entry["category"]?.stringValue ?? ""
            let parsed = EmailCategory(rawValue: rawCategory)
            let category = parsed ?? .unknown
            // An unparseable category means we do not know what this is, so it is kept.
            let mustKeep = (entry["mustKeep"]?.boolValue ?? true) || parsed == nil
            let confidence = min(max(entry["confidence"]?.doubleValue ?? 0, 0), 1)

            return MessageVerdict(
                messageId: id,
                category: category,
                mustKeep: mustKeep,
                confidence: parsed == nil ? min(confidence, 0.3) : confidence,
                reason: entry["reason"]?.stringValue ?? "no reason given",
                isUnsure: entry["unsure"]?.boolValue ?? false
            )
        }
    }

    /// Render the user-message payload for a batch.
    public static func userMessage(for messages: [MessageClassificationRequest]) -> String {
        var lines: [String] = ["Classify these messages:", ""]
        for message in messages {
            lines.append("- id: \(message.messageId)")
            lines.append("  from: \(message.displayName) <\(message.senderEmail)>")
            lines.append("  subject: \(message.subject)")
            lines.append("  age_days: \(message.ageDays)")
            if let provider = message.providerCategory {
                lines.append("  provider_filed_under: \(provider.displayName)")
            }
            if message.hasUnsubscribe {
                lines.append("  has_unsubscribe: true")
            }
            if let summary = message.senderVerdictSummary {
                lines.append("  sender_was_judged: \(summary)")
            }
            if let snippet = message.snippet, !snippet.isEmpty {
                let clipped = snippet.count > 220 ? String(snippet.prefix(220)) + "…" : snippet
                lines.append("  preview: \(clipped.replacingOccurrences(of: "\n", with: " "))")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
