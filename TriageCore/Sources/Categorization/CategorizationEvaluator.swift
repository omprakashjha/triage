import Foundation

/// Measures a categorization engine against human labels.
///
/// The headline metric is deliberately NOT overall accuracy. The costs here are wildly
/// asymmetric:
///
///   - a receipt misfiled as a promotion is DELETED, and after Gmail's 30-day trash
///     window that is unrecoverable
///   - a promotion misfiled as unknown is KEPT, and costs the user one extra row
///
/// Overall accuracy happily trades those against each other, which makes it the wrong
/// number to optimise. `destructivePrecision` is the one that matters: of everything
/// the pipeline would auto-delete, what fraction is genuinely disposable?
///
/// Note this evaluates the REAL pipeline — it runs `ActionPlanner` with the supplied
/// rules and inspects what would actually be approved for deletion — rather than a
/// proxy for it. A tier or approval regression shows up here even if categorization
/// itself did not change.
public struct CategorizationEvaluator: Sendable {

    private let rules: ActionRules

    public init(rules: ActionRules = .default) {
        self.rules = rules
    }

    public func evaluate(
        emails: [EmailMetadata],
        results: [CategorizationResult],
        labels: [GoldenLabel],
        accountId: Int64 = 1,
        now: Date = Date()
    ) -> EvaluationReport {
        let labelsBySender = Dictionary(
            labels.map { ($0.senderEmail.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let resultsById = Dictionary(
            results.map { ($0.messageId, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Only mail from a labelled sender can be scored.
        var scored: [(email: EmailMetadata, result: CategorizationResult, label: GoldenLabel)] = []
        for email in emails {
            guard let label = labelsBySender[email.senderEmail.lowercased()],
                  let result = resultsById[email.messageId] else { continue }
            scored.append((email, result, label))
        }

        guard !scored.isEmpty else {
            return EvaluationReport(
                labelledSenders: labels.count,
                evaluatedEmails: 0,
                destructiveTotal: 0,
                destructivePrecision: nil,
                destructiveFalsePositives: [],
                disposableSweptFraction: nil,
                categoryAccuracy: nil,
                perCategory: [:],
                calibration: []
            )
        }

        // Materialize the engine's decisions onto the emails so the planner sees what
        // the app would actually see after a scan.
        let decided: [EmailMetadata] = scored.map { entry in
            var email = entry.email
            email.category = entry.result.category
            email.safetyTier = entry.result.safetyTier
            email.categoryConfidence = entry.result.confidence
            email.categoryReason = entry.result.reason
            return email
        }

        let plan = ActionPlanner(rules: rules).generatePlan(emails: decided, accountId: accountId)

        // The destructive path: approved items whose action is deletion.
        var destructiveIds: Set<String> = []
        for item in plan.items where item.isApproved && item.action == .deleted {
            for entry in item.entries { destructiveIds.insert(entry.messageId) }
        }

        var falsePositives: [EvaluationReport.Finding] = []
        var destructiveDisposable = 0
        for entry in scored where destructiveIds.contains(entry.email.messageId) {
            if entry.label.disposition == .mustKeep {
                falsePositives.append(
                    EvaluationReport.Finding(
                        senderEmail: entry.email.senderEmail,
                        subject: entry.email.subject,
                        predictedCategory: entry.result.category,
                        expectedCategory: entry.label.expectedCategory,
                        confidence: entry.result.confidence,
                        reason: entry.result.reason,
                        note: entry.label.note
                    )
                )
            } else {
                destructiveDisposable += 1
            }
        }

        let destructiveTotal = destructiveIds.count
        let destructivePrecision: Double? = destructiveTotal > 0
            ? Double(destructiveDisposable) / Double(destructiveTotal)
            : nil

        // Secondary: how much of the genuinely disposable mail actually got swept.
        // Low recall is an inconvenience; low precision is data loss.
        let disposableTotal = scored.filter { $0.label.disposition == .disposable }.count
        let disposableSwept = scored.filter {
            $0.label.disposition == .disposable && destructiveIds.contains($0.email.messageId)
        }.count
        let disposableSweptFraction: Double? = disposableTotal > 0
            ? Double(disposableSwept) / Double(disposableTotal)
            : nil

        // Category-level accuracy.
        let correct = scored.filter { $0.result.category == $0.label.expectedCategory }.count
        let categoryAccuracy = Double(correct) / Double(scored.count)

        var perCategory: [EmailCategory: ClassMetrics] = [:]
        for category in EmailCategory.allCases {
            let predicted = scored.filter { $0.result.category == category }
            let actual = scored.filter { $0.label.expectedCategory == category }
            guard !predicted.isEmpty || !actual.isEmpty else { continue }

            let truePositives = predicted.filter { $0.label.expectedCategory == category }.count
            perCategory[category] = ClassMetrics(
                predictedCount: predicted.count,
                actualCount: actual.count,
                precision: predicted.isEmpty ? nil : Double(truePositives) / Double(predicted.count),
                recall: actual.isEmpty ? nil : Double(truePositives) / Double(actual.count)
            )
        }

        return EvaluationReport(
            labelledSenders: labels.count,
            evaluatedEmails: scored.count,
            destructiveTotal: destructiveTotal,
            destructivePrecision: destructivePrecision,
            destructiveFalsePositives: falsePositives,
            disposableSweptFraction: disposableSweptFraction,
            categoryAccuracy: categoryAccuracy,
            perCategory: perCategory,
            calibration: Self.calibration(for: scored)
        )
    }

    /// Bucket predictions by stated confidence and report how often they were right.
    ///
    /// The engine's confidence values are hand-assigned literals (0.95, 0.85, 0.7, …),
    /// not calibrated probabilities. This is what shows whether "85% confident"
    /// actually corresponds to being right 85% of the time — and therefore whether
    /// the auto-approve threshold can be set from evidence instead of intuition.
    static func calibration(
        for scored: [(email: EmailMetadata, result: CategorizationResult, label: GoldenLabel)]
    ) -> [CalibrationBucket] {
        let bounds: [(lower: Double, upper: Double)] = [
            (0.0, 0.5), (0.5, 0.7), (0.7, 0.85), (0.85, 1.01),
        ]

        return bounds.compactMap { bound in
            let inBucket = scored.filter {
                $0.result.confidence >= bound.lower && $0.result.confidence < bound.upper
            }
            guard !inBucket.isEmpty else { return nil }
            let correct = inBucket.filter { $0.result.category == $0.label.expectedCategory }.count
            return CalibrationBucket(
                lowerBound: bound.lower,
                upperBound: min(bound.upper, 1.0),
                count: inBucket.count,
                observedAccuracy: Double(correct) / Double(inBucket.count)
            )
        }
    }
}

// MARK: - Report

public struct EvaluationReport: Sendable {
    /// A case where the pipeline would have deleted mail the user said must be kept.
    /// These are the only failures that are unrecoverable, so they are listed in full
    /// rather than summarized.
    public struct Finding: Sendable {
        public let senderEmail: String
        public let subject: String
        public let predictedCategory: EmailCategory
        public let expectedCategory: EmailCategory
        public let confidence: Double
        public let reason: String
        public let note: String?
    }

    public let labelledSenders: Int
    public let evaluatedEmails: Int
    /// How many emails the pipeline would auto-delete.
    public let destructiveTotal: Int
    /// THE metric: fraction of auto-deleted mail that is genuinely disposable.
    /// `nil` when the plan would delete nothing.
    public let destructivePrecision: Double?
    public let destructiveFalsePositives: [Finding]
    /// Fraction of disposable mail actually swept. Secondary — low values are an
    /// inconvenience, not a loss.
    public let disposableSweptFraction: Double?
    public let categoryAccuracy: Double?
    public let perCategory: [EmailCategory: ClassMetrics]
    public let calibration: [CalibrationBucket]

    /// Whether the destructive path is clean. A single false positive fails this:
    /// one deleted tax document is not offset by a thousand correct deletions.
    public var isDestructivePathClean: Bool {
        destructiveFalsePositives.isEmpty
    }

    /// A short verdict suitable for showing above the detail.
    public var headline: String {
        guard evaluatedEmails > 0 else {
            return "No labelled senders yet — label some senders to measure accuracy."
        }
        guard let precision = destructivePrecision else {
            return "Nothing would be auto-deleted for these \(evaluatedEmails) labelled emails."
        }
        let percent = String(format: "%.1f%%", precision * 100)
        if isDestructivePathClean {
            return "Destructive precision \(percent) — no must-keep mail would be deleted."
        }
        return "Destructive precision \(percent) — "
            + "\(destructiveFalsePositives.count) must-keep emails would be DELETED."
    }
}

public struct ClassMetrics: Sendable {
    public let predictedCount: Int
    public let actualCount: Int
    public let precision: Double?
    public let recall: Double?
}

public struct CalibrationBucket: Sendable {
    public let lowerBound: Double
    public let upperBound: Double
    public let count: Int
    public let observedAccuracy: Double

    public var label: String {
        String(format: "%.0f–%.0f%%", lowerBound * 100, upperBound * 100)
    }

    /// Positive means the engine is overconfident in this band.
    public var overconfidenceGap: Double {
        let stated = (lowerBound + upperBound) / 2
        return stated - observedAccuracy
    }
}
