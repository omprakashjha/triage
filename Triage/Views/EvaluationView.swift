import SwiftUI
import TriageCore

/// The accuracy report: how the engine performs against senders you have labelled.
///
/// Exists because the app previously had no way to know its own accuracy. The unit
/// tests assert that specific inputs produce specific categories, but the expected
/// values were written by whoever wrote the rules — that measures self-consistency,
/// not correctness.
struct EvaluationView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let report = appState.evaluationReport {
                    verdict(report)
                    if !report.destructiveFalsePositives.isEmpty {
                        falsePositives(report)
                    }
                    secondaryMetrics(report)
                    calibration(report)
                    perCategory(report)
                } else {
                    Text("Run an evaluation to see how the engine performs on your labelled senders.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Divider()
                labelledSenders
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .task(id: appState.selectedAccount?.id) {
            if let accountId = appState.selectedAccount?.id {
                await appState.loadGoldenLabels(accountId: accountId)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accuracy")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Label senders in the Senders view (“Safe to delete” or “Must keep”), then measure. The top senders by volume cover most of a mailbox, so a useful set is an evening's work, not a month's.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button {
                    Task {
                        if let accountId = appState.selectedAccount?.id {
                            await appState.runEvaluation(accountId: accountId)
                        }
                    }
                } label: {
                    if appState.isEvaluating {
                        ProgressView().controlSize(.small)
                        Text("Measuring…")
                    } else {
                        Label("Run evaluation", systemImage: "chart.bar.doc.horizontal")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.isEvaluating || appState.goldenLabels.isEmpty)

                Button("Export golden set") {
                    Task {
                        if let accountId = appState.selectedAccount?.id {
                            await appState.exportGoldenSet(accountId: accountId)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(appState.goldenLabels.isEmpty)

                Text("\(appState.goldenLabels.count) senders labelled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let path = appState.exportedGoldenSetPath {
                Text("Exported to \(path)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Verdict

    private func verdict(_ report: EvaluationReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: report.isDestructivePathClean
                    ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(report.isDestructivePathClean ? .green : .red)

                VStack(alignment: .leading, spacing: 2) {
                    Text(report.headline)
                        .font(.headline)
                    Text("\(report.evaluatedEmails) emails from \(report.labelledSenders) labelled senders")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Destructive precision is the number that matters. Of everything the plan would auto-delete, what fraction is genuinely disposable? A promotion left behind costs you one row; a deleted receipt is gone after Gmail's 30-day trash window.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill((report.isDestructivePathClean ? Color.green : Color.red).opacity(0.08))
        )
    }

    // MARK: - False positives

    private func falsePositives(_ report: EvaluationReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Would have been deleted but must be kept")
                .font(.headline)
                .foregroundStyle(.red)

            Text("Listed in full rather than summarized — these are the only failures that are unrecoverable.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(report.destructiveFalsePositives.enumerated()), id: \.offset) { _, finding in
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.subject)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(finding.senderEmail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text("called \(finding.predictedCategory.displayName)")
                            .foregroundStyle(.red)
                        Text("• you said \(finding.expectedCategory.displayName)")
                            .foregroundStyle(.secondary)
                        Text("• \(Int(finding.confidence * 100))% confident")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                    Text(finding.reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .italic()
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.06)))
            }
        }
    }

    // MARK: - Secondary metrics

    private func secondaryMetrics(_ report: EvaluationReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Secondary")
                .font(.headline)

            metricRow(
                "Category accuracy",
                report.categoryAccuracy,
                "How often the assigned category matched your label."
            )
            metricRow(
                "Disposable mail swept",
                report.disposableSweptFraction,
                "How much genuinely disposable mail the plan actually cleans up. Low is an inconvenience, not a loss."
            )
        }
    }

    private func metricRow(_ label: String, _ value: Double?, _ explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label)
                    .frame(width: 180, alignment: .leading)
                if let value {
                    Text(String(format: "%.1f%%", value * 100))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .font(.callout)
            Text(explanation)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Calibration

    private func calibration(_ report: EvaluationReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Confidence calibration")
                .font(.headline)
            Text("The engine's confidence values are hand-assigned constants, not measured probabilities. This shows whether they mean anything — and therefore whether the auto-approve threshold can be set from evidence.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if report.calibration.isEmpty {
                Text("Not enough data.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(report.calibration.enumerated()), id: \.offset) { _, bucket in
                    HStack {
                        Text("stated \(bucket.label)")
                            .frame(width: 120, alignment: .leading)
                        Text("actual \(String(format: "%.0f%%", bucket.observedAccuracy * 100))")
                            .monospacedDigit()
                            .frame(width: 90, alignment: .leading)
                        Text("n=\(bucket.count)")
                            .foregroundStyle(.secondary)
                        if bucket.overconfidenceGap > 0.1 {
                            Text("overconfident")
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: - Per category

    private func perCategory(_ report: EvaluationReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Per category")
                .font(.headline)

            ForEach(EmailCategory.allCases, id: \.self) { category in
                if let metrics = report.perCategory[category] {
                    HStack {
                        Label(category.displayName, systemImage: category.iconName)
                            .frame(width: 150, alignment: .leading)
                        Text(metrics.precision.map { String(format: "P %.0f%%", $0 * 100) } ?? "P —")
                            .monospacedDigit()
                            .frame(width: 70, alignment: .leading)
                        Text(metrics.recall.map { String(format: "R %.0f%%", $0 * 100) } ?? "R —")
                            .monospacedDigit()
                            .frame(width: 70, alignment: .leading)
                        Text("predicted \(metrics.predictedCount) / actual \(metrics.actualCount)")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: - Labelled senders

    private var labelledSenders: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Labelled senders")
                .font(.headline)

            if appState.goldenLabels.isEmpty {
                Text("None yet. Open a sender in the Senders view and use “Label for accuracy testing”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appState.goldenLabels) { label in
                    HStack {
                        Image(systemName: label.disposition == .mustKeep ? "lock.fill" : "trash")
                            .font(.caption2)
                            .foregroundStyle(label.disposition == .mustKeep ? .blue : .secondary)
                        Text(label.senderEmail)
                            .lineLimit(1)
                        Text(label.expectedCategory.displayName)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(label.disposition.displayName)
                            .foregroundStyle(.secondary)
                        Button {
                            Task {
                                if let accountId = appState.selectedAccount?.id {
                                    await appState.removeGoldenLabel(
                                        senderEmail: label.senderEmail,
                                        accountId: accountId
                                    )
                                }
                            }
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                    .font(.caption)
                }
            }
        }
    }
}
