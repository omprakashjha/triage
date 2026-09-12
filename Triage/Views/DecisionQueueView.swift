import SwiftUI
import TriageCore

/// A short interview instead of a long list.
///
/// A review queue is the wrong unit of work. On a real mailbox 232 emails needed review while
/// six senders held 58% of them — so the user was asked to scroll 232 rows to make six
/// decisions. This screen ranks senders by how much mail one answer resolves and asks about
/// them one at a time, with the evidence and the model's reasoning on screen.
///
/// The second job is measurement, and it is why Confirm exists as a first-class action rather
/// than only Correct. A correction forces an outcome, so scoring the pipeline against one is
/// circular — it returned 100% over 91 emails and meant nothing. A confirmation records that
/// the user endorsed a verdict the model reached on its own, which is the only ground truth
/// this app can gather that can actually measure it.
struct DecisionQueueView: View {
    @EnvironmentObject private var appState: AppState
    @State private var index = 0
    @State private var overriding = false
    @State private var chosenCategory: EmailCategory = .promotion
    @State private var chosenMustKeep = true
    @State private var subjectPattern = ""

    private var accountId: Int64? { appState.settingsTarget?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if appState.isLoadingCandidates {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let candidate = current {
                ScrollView {
                    card(for: candidate)
                        .padding(20)
                }
            } else {
                emptyState
            }
        }
        .task(id: accountId) {
            if let accountId {
                await appState.loadSettings(accountId: accountId)
                await appState.loadTriageCandidates(accountId: accountId)
            }
        }
    }

    private var current: TriageCandidate? {
        guard index < appState.triageCandidates.count else { return nil }
        return appState.triageCandidates[index]
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Decide")
                    .font(.title2.weight(.semibold))
                Spacer()
                // The agreement rate IS the accuracy figure — confirmations are judgements the
                // user made against verdicts the model reached independently.
                if appState.agreement.confirmed + appState.agreement.overturned > 0 {
                    let total = appState.agreement.confirmed + appState.agreement.overturned
                    let pct = Int(
                        (Double(appState.agreement.confirmed) / Double(total) * 100).rounded()
                    )
                    Text("You've agreed with \(pct)% of \(total) verdicts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !appState.triageCandidates.isEmpty {
                let remaining = appState.triageCandidates.count - index
                let mail = appState.triageCandidates[index...].reduce(0) { $0 + $1.pendingCount }
                Text("\(remaining) decision\(remaining == 1 ? "" : "s") left, covering \(mail) emails")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let status = appState.correctionStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(20)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("Nothing left to decide")
                .font(.headline)
            Text("Every sender with mail awaiting review has been ruled on. Scan again or widen the scan scope to find more.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func card(for candidate: TriageCandidate) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Leverage stated up front, because it is why this sender is being asked about.
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(candidate.senderEmail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(candidate.pendingCount)")
                        .font(.title.weight(.semibold))
                    Text("awaiting review")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if candidate.looksMixed {
                Label(
                    "Gmail filed this sender's mail under more than one heading — a subject split is probably the right answer.",
                    systemImage: "arrow.triangle.branch"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            verdictBlock(candidate)
            evidenceBlock(candidate)

            Divider()

            if overriding {
                overrideControls(candidate)
            } else {
                actions(candidate)
            }
        }
    }

    private func verdictBlock(_ candidate: TriageCandidate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The app says")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text((candidate.currentCategory ?? .unknown).displayName)
                    .font(.callout.weight(.medium))
                if let tier = candidate.currentTier {
                    Text(tier.displayName)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(tierColor(tier).opacity(0.15), in: Capsule())
                        .foregroundStyle(tierColor(tier))
                }
                if candidate.modelWasUnsure {
                    Text("model unsure")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }

            if let reason = candidate.currentReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Shown separately, because the pipeline may have overridden the model and the
            // user should see what the model actually said either way.
            if let modelReason = candidate.modelReason,
               candidate.currentReason?.contains(modelReason) != true {
                Text("Model: \(modelReason)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func evidenceBlock(_ candidate: TriageCandidate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent subjects")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(candidate.sampleSubjects.prefix(5), id: \.self) { subject in
                Text("• \(subject)")
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !candidate.providerLabelCounts.isEmpty {
                Text(
                    candidate.providerLabelCounts
                        .sorted { $0.value > $1.value }
                        .map { "\($0.key) \($0.value)" }
                        .joined(separator: " · ")
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
    }

    private func actions(_ candidate: TriageCandidate) -> some View {
        HStack(spacing: 10) {
            Button {
                Task {
                    guard let accountId else { return }
                    await appState.confirmCandidate(candidate, accountId: accountId)
                }
            } label: {
                Label("That's right", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .disabled(candidate.currentCategory == nil)
            .help("Records this as ground truth. Nothing is re-categorized.")

            Button("No, it's…") {
                chosenCategory = candidate.currentCategory ?? .promotion
                chosenMustKeep = candidate.currentTier != .safe
                subjectPattern = ""
                overriding = true
            }

            Spacer()

            // Skip is deliberate: forcing a decision on a sender the user is unsure about
            // would poison the very ground truth this screen exists to collect.
            Button("Skip") { advance() }
                .buttonStyle(.borderless)
                .help("Leaves this sender undecided and records nothing.")
        }
    }

    private func overrideControls(_ candidate: TriageCandidate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("It's actually", selection: $chosenCategory) {
                ForEach(EmailCategory.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.menu)

            Toggle("Never delete this automatically", isOn: $chosenMustKeep)

            TextField(
                "Only subjects containing… (optional)",
                text: $subjectPattern
            )
            .textFieldStyle(.roundedBorder)
            Text("Use a word that recurs — “factuur”, “statement” — when this sender mixes mail you want with mail you don't.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") { overriding = false }
                Spacer()
                Button("Save decision") {
                    Task {
                        guard let accountId else { return }
                        await appState.decideCandidate(
                            candidate,
                            accountId: accountId,
                            category: chosenCategory,
                            mustKeep: chosenMustKeep,
                            subjectPattern: subjectPattern.count >= 3 ? subjectPattern : nil
                        )
                        overriding = false
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func advance() {
        if index < appState.triageCandidates.count { index += 1 }
    }

    private func tierColor(_ tier: SafetyTier) -> Color {
        switch tier {
        case .safe: return .orange
        case .review: return .blue
        case .protected_: return .green
        }
    }
}
