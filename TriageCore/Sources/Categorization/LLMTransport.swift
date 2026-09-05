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

    /// Short body previews, when the user has allowed sending them.
    ///
    /// The single most informative field available and previously unused: subjects are
    /// often opaque ("Uw overzicht") where the first line of the body is not. Gated behind
    /// a setting because it is a real escalation in what leaves the machine — a subject
    /// line is metadata, a body preview is content.
    public let sampleSnippets: [String]

    /// How the mail provider itself classified this sender's messages, and how many of
    /// each.
    ///
    /// Both a strong hint and the clearest possible signal that a sender is MIXED: a
    /// sender showing both Promotions and Updates is one the model should split by subject
    /// rather than label wholesale.
    public let providerLabelCounts: [String: Int]

    /// Whether the user has ever replied to this sender, from thread participation.
    public let userHasReplied: Bool

    public init(
        senderEmail: String,
        displayName: String,
        sampleSubjects: [String],
        totalEmails: Int,
        hasUnsubscribe: Bool,
        averageIntervalDays: Double? = nil,
        sampleSnippets: [String] = [],
        providerLabelCounts: [String: Int] = [:],
        userHasReplied: Bool = false
    ) {
        self.senderEmail = senderEmail
        self.displayName = displayName
        self.sampleSubjects = sampleSubjects
        self.totalEmails = totalEmails
        self.hasUnsubscribe = hasUnsubscribe
        self.averageIntervalDays = averageIntervalDays
        self.sampleSnippets = sampleSnippets
        self.providerLabelCounts = providerLabelCounts
        self.userHasReplied = userHasReplied
    }

    /// Whether the provider's own labels disagree about this sender's mail.
    public var looksMixed: Bool {
        providerLabelCounts.filter { $0.value > 0 }.count > 1
    }
}

/// A correction the user made, rendered for the model as a worked example.
///
/// This is what makes the model learn THIS mailbox rather than mail in general. A handful
/// of corrections teach it which utilities, which bank and which language it is looking
/// at, and that generalises to senders the user never corrected.
public struct CorrectionExample: Sendable, Equatable {
    public let senderEmail: String
    public let subjectPattern: String?
    public let category: EmailCategory
    public let mustKeep: Bool

    public init(
        senderEmail: String,
        subjectPattern: String?,
        category: EmailCategory,
        mustKeep: Bool
    ) {
        self.senderEmail = senderEmail
        self.subjectPattern = subjectPattern
        self.category = category
        self.mustKeep = mustKeep
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

    /// Subject fragments identifying this sender's DISPOSABLE mail.
    ///
    /// Exists because senders are not homogeneous and a single verdict per sender is
    /// structurally unable to describe them. One real sender in the test mailbox sends 46
    /// marketing messages and 58 travel receipts from the same address; no sender-level
    /// answer is correct for both halves. Rather than pay for a per-message classification
    /// call, the model is asked to name the split, and it is then applied per message.
    public let disposableSubjects: [String]
    /// Subject fragments identifying mail from this sender that must be KEPT.
    public let keepSubjects: [String]

    /// The model declining to answer.
    ///
    /// A genuinely different state from a low-confidence guess, and a more useful one: a
    /// forced answer on three uninformative subjects is noise that still carries a
    /// category, whereas an abstention routes the sender to a human without pretending.
    public let isUnsure: Bool

    public init(
        senderEmail: String,
        category: EmailCategory,
        mustKeep: Bool,
        isRealPerson: Bool,
        confidence: Double,
        reason: String,
        disposableSubjects: [String] = [],
        keepSubjects: [String] = [],
        isUnsure: Bool = false
    ) {
        self.senderEmail = senderEmail.lowercased()
        self.category = category
        self.mustKeep = mustKeep
        self.isRealPerson = isRealPerson
        self.confidence = confidence
        self.reason = reason
        self.disposableSubjects = disposableSubjects.map { $0.lowercased() }.filter { !$0.isEmpty }
        self.keepSubjects = keepSubjects.map { $0.lowercased() }.filter { !$0.isEmpty }
        self.isUnsure = isUnsure
    }

    /// The tier this verdict implies on its own.
    ///
    /// A real person, mail the model says must be kept, or an abstention is never
    /// auto-actionable.
    public var impliedTier: SafetyTier {
        if isRealPerson { return .protected_ }
        if isUnsure || mustKeep { return .review }
        return .safe
    }

    /// This verdict resolved for one specific message.
    ///
    /// Where a subject split applies, it overrides the sender-level answer — that is the
    /// whole point of having asked for it. A keep pattern wins over a disposable one when
    /// both somehow match, because the asymmetry always favours keeping.
    public func resolved(forSubject subject: String) -> SenderVerdict {
        let lowered = subject.lowercased()

        if keepSubjects.contains(where: { lowered.contains($0) }) {
            return SenderVerdict(
                senderEmail: senderEmail,
                category: category == .promotion || category == .newsletter
                    ? .transactional : category,
                mustKeep: true,
                isRealPerson: isRealPerson,
                confidence: confidence,
                reason: reason + " — this message matches a keep pattern",
                disposableSubjects: disposableSubjects,
                keepSubjects: keepSubjects,
                isUnsure: isUnsure
            )
        }

        if disposableSubjects.contains(where: { lowered.contains($0) }) {
            return SenderVerdict(
                senderEmail: senderEmail,
                category: category.isTypicallyDisposable ? category : .promotion,
                mustKeep: false,
                isRealPerson: isRealPerson,
                confidence: confidence,
                reason: reason + " — this message matches a promotional pattern",
                disposableSubjects: disposableSubjects,
                keepSubjects: keepSubjects,
                isUnsure: isUnsure
            )
        }

        // No split matched. If the model gave a split at all it was describing a mixed
        // sender, so an unmatched message is one it did not account for — which is an
        // ABSENCE of a verdict for this message, not a verdict to keep it. Marked unsure so
        // the merge treats it as carrying no information: asserting `mustKeep` alone let a
        // gap in the model's pattern list outrank two independent classifiers that had both
        // called the message marketing (48 emails on the live mailbox).
        if !disposableSubjects.isEmpty || !keepSubjects.isEmpty {
            return SenderVerdict(
                senderEmail: senderEmail,
                category: category,
                mustKeep: true,
                isRealPerson: isRealPerson,
                confidence: min(confidence, 0.6),
                reason: reason + " — mixed sender, this message matched neither pattern",
                disposableSubjects: disposableSubjects,
                keepSubjects: keepSubjects,
                isUnsure: true
            )
        }

        return self
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

    /// Classify a batch of senders.
    ///
    /// `corrections` are the user's own past fixes, passed on every call so the model is
    /// looking at this specific mailbox rather than mail in general. They travel with the
    /// request rather than being baked in at construction because they change while the app
    /// is running — a correction made a moment ago must affect the very next batch.
    func classify(
        senders: [SenderClassificationRequest],
        corrections: [CorrectionExample]
    ) async throws -> [SenderVerdict]
}

public extension LLMTransport {
    /// Convenience for callers with nothing learned yet.
    func classify(senders: [SenderClassificationRequest]) async throws -> [SenderVerdict] {
        try await classify(senders: senders, corrections: [])
    }
}

/// The prompt and output contract, kept in one reviewable place.
///
/// Structured output is forced via a schema rather than parsed out of prose: a
/// classifier whose output shape can drift is a classifier that will eventually
/// mis-assign a tier.
public enum SenderClassificationPrompt {
    public static let version = "sender.v2"

    public static let system = """
        You classify EMAIL SENDERS for an inbox cleanup tool. For each sender you are \
        given their address, display name, how many messages they sent, whether their \
        mail carries an unsubscribe header, how often they write, a sample of subject \
        lines, and where the mail provider filed their messages.

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

        THE MAIL IS OFTEN NOT IN ENGLISH. Classify by meaning, never by matching English \
        words. A Dutch annual utility statement ("jaarafrekening"), a German invoice \
        ("Rechnung") and a French one ("facture") are all transactional and all mustKeep. \
        Do not treat unfamiliar vocabulary as promotional.

        SAY WHEN YOU DO NOT KNOW. Set unsure=true if the samples genuinely do not \
        support a judgement — too few, too vague, or all in a language whose meaning you \
        cannot make out. An honest abstention sends the sender to the user, which is \
        cheap. A confident wrong answer can destroy mail, which is not. Never invent \
        facts about a sender to avoid abstaining.

        MANY SENDERS ARE MIXED, and one label cannot describe them. A rail operator sends \
        both fare promotions and travel receipts from the same address; a retailer sends \
        both offers and order confirmations. When the samples show a sender doing both, \
        or when the provider filed their mail under more than one heading:
        - put short subject fragments identifying the DISPOSABLE mail in disposableSubjects
        - put short subject fragments identifying the mail that MUST BE KEPT in keepSubjects
        Use the sender's own language for these fragments, taken from the subjects you were \
        shown, and keep them specific enough not to match the other group. Leave both empty \
        for a sender whose mail is all one kind.

        Judge on the evidence given. When the samples are ambiguous, prefer mustKeep=true — \
        the cost of wrongly keeping a promotion is one extra row in a list, and the cost of \
        wrongly discarding a receipt is permanent.

        A sender can be promotional AND mustKeep: large retailers send offers and order \
        confirmations from the same address.

        confidence is your own probability that the category is correct, from 0 to 1.
        reason is one short clause naming the evidence you used, for the user to read.
        """

    /// Corrections the user has already made, rendered as authoritative examples.
    ///
    /// Presented as settled fact rather than as suggestions, because that is what they
    /// are: the user has looked at this mail and said what it is. Their value is in
    /// generalisation — knowing that one Dutch water company is transactional tells the
    /// model what to do with the gas company it has not seen.
    public static func correctionsSection(_ corrections: [CorrectionExample]) -> String {
        guard !corrections.isEmpty else { return "" }

        let header = "The user has already corrected these senders by hand. They are "
            + "CORRECT by definition. Apply the same reasoning to similar senders, and "
            + "never contradict one of them:"

        var lines: [String] = ["", header, ""]
        for correction in corrections.prefix(40) {
            let scope: String
            if let pattern = correction.subjectPattern {
                scope = " (subjects containing \"\(pattern)\")"
            } else {
                scope = ""
            }
            let keep = correction.mustKeep ? ", must be kept" : ", disposable"
            let category = correction.category.rawValue
            lines.append("- \(correction.senderEmail)\(scope): \(category)\(keep)")
        }
        return lines.joined(separator: "\n")
    }

    /// The full system prompt for a run, including anything learned from the user.
    public static func systemPrompt(corrections: [CorrectionExample] = []) -> String {
        let base: String = system
        return base + correctionsSection(corrections)
    }

    /// JSON Schema for the forced tool-use / structured-output call.
    ///
    /// Typed as `JSONValue` rather than `[String: Any]` so it stays `Sendable` and can
    /// be bridged to the SDK's document type without casting.
    ///
    /// Deliberately split into named parts. As one nested literal it grew past what the
    /// Swift type-checker will infer in reasonable time, and a schema is exactly the kind
    /// of thing that should stay readable anyway.
    private static var categoryProperty: JSONValue {
        .object([
            "type": "string",
            "enum": .array(EmailCategory.allCases.map { .string($0.rawValue) }),
        ])
    }

    private static var subjectFragmentArray: JSONValue {
        .object([
            "type": "array",
            "items": .object(["type": "string", "maxLength": 60]),
        ])
    }

    private static var verdictProperties: JSONValue {
        .object([
            "senderEmail": .object(["type": "string"]),
            "category": categoryProperty,
            "mustKeep": .object(["type": "boolean"]),
            "isRealPerson": .object(["type": "boolean"]),
            "confidence": .object(["type": "number", "minimum": 0, "maximum": 1]),
            "reason": .object(["type": "string", "maxLength": 160]),
            "unsure": .object(["type": "boolean"]),
            "disposableSubjects": subjectFragmentArray,
            "keepSubjects": subjectFragmentArray,
        ])
    }

    private static var verdictItem: JSONValue {
        .object([
            "type": "object",
            "properties": verdictProperties,
            "required": .array([
                "senderEmail", "category", "mustKeep",
                "isRealPerson", "confidence", "reason",
            ]),
        ])
    }

    public static var outputSchema: JSONValue {
        .object([
            "type": "object",
            "properties": .object([
                "verdicts": .object([
                    "type": "array",
                    "items": verdictItem,
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
            let isUnsure = entry["unsure"]?.boolValue ?? false

            // Subject fragments are free text from the model, so they are treated as
            // untrusted input: trimmed, lowercased, length-capped, and anything trivially
            // short dropped. A one-character fragment would match nearly every subject and
            // could sweep a sender's entire mail into the disposable half.
            func fragments(_ key: String) -> [String] {
                (entry[key]?.arrayValue ?? [])
                    .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.count >= 3 && $0.count <= 60 }
                    .prefix(8)
                    .map { $0 }
            }

            return SenderVerdict(
                senderEmail: sender,
                category: category,
                mustKeep: mustKeep,
                isRealPerson: isRealPerson,
                confidence: parsedCategory == nil ? min(confidence, 0.3) : confidence,
                reason: reason,
                disposableSubjects: fragments("disposableSubjects"),
                keepSubjects: fragments("keepSubjects"),
                isUnsure: isUnsure
            )
        }
    }

    /// Render the user-message payload for a batch.
    ///
    /// What leaves the machine: sender address, display name, counts, cadence, the
    /// provider's own labels, and subject lines — plus, ONLY when the user has enabled it,
    /// a short body preview per sender. That last one is a genuine escalation from
    /// metadata to content and is why the setting exists and says so plainly. Full message
    /// bodies are never fetched, let alone sent.
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
            if sender.userHasReplied {
                lines.append("  user_has_replied: true")
            }
            if !sender.providerLabelCounts.isEmpty {
                let filed = sender.providerLabelCounts
                    .sorted { $0.value > $1.value }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: ", ")
                lines.append("  provider_filed_under: \(filed)")
                if sender.looksMixed {
                    lines.append(
                        "  NOTE: the provider filed this sender's mail under more than one "
                            + "heading, so it is probably mixed — split it by subject."
                    )
                }
            }
            lines.append("  subjects:")
            for subject in sender.sampleSubjects.prefix(8) {
                lines.append("    - \(subject)")
            }
            if !sender.sampleSnippets.isEmpty {
                lines.append("  body_previews:")
                for snippet in sender.sampleSnippets.prefix(3) {
                    let clipped = snippet.count > 200
                        ? String(snippet.prefix(200)) + "…"
                        : snippet
                    lines.append("    - \(clipped.replacingOccurrences(of: "\n", with: " "))")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
