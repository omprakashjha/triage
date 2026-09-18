import SwiftUI
import TriageCore

/// Subscriptions ranked by the mail ending them will stop ARRIVING.
///
/// This is the only screen in the app that reduces future mail rather than sorting past mail. The
/// capability existed for months — the service handles RFC 8058 one-click, mailto and browser
/// fallback, and a button sat on the senders screen — and was used exactly zero times, because
/// nothing ever said which subscriptions were worth ending.
struct UnsubscribeView: View {
    @EnvironmentObject private var appState: AppState

    @State private var selected: Set<String> = []
    @State private var showConfirmation = false
    @State private var isRunning = false

    private var accountId: Int64? { appState.selectedAccount?.id }

    /// Only what the app is prepared to recommend. Dormant and trickle senders are still loaded and
    /// shown further down, but they are never preselected or counted as a win.
    private var actionable: [UnsubscribeCandidate] {
        appState.unsubscribeCandidates.filter {
            let r = $0.recommendation()
            return r == .unsubscribe || r == .unsubscribeWithCollateral
        }
    }

    private var inert: [UnsubscribeCandidate] {
        appState.unsubscribeCandidates.filter {
            let r = $0.recommendation()
            return r == .dormant || r == .notWorthIt
        }
    }

    private var selectedYearlyVolume: Int {
        Int(appState.unsubscribeCandidates
            .filter { selected.contains($0.senderEmail) }
            .reduce(0) { $0 + $1.projectedYearlyVolume }
            .rounded())
    }

    private var selectedWithCollateral: [UnsubscribeCandidate] {
        appState.unsubscribeCandidates.filter {
            selected.contains($0.senderEmail) && $0.hasCollateral
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if appState.unsubscribeLoadedAccountId != accountId {
                ProgressView("Reading your subscriptions…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.unsubscribeCandidates.isEmpty {
                emptyState
            } else {
                List {
                    if !actionable.isEmpty {
                        Section("Worth ending") {
                            ForEach(actionable) { row($0) }
                        }
                    }
                    if !inert.isEmpty {
                        Section("Not worth it") {
                            ForEach(inert) { row($0) }
                        }
                    }
                }
                .listStyle(.inset)
            }

            if let message = appState.unsubscribeMessage {
                Divider()
                Text(message)
                    .font(.caption)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: accountId) {
            guard let accountId else { return }
            await appState.loadUnsubscribeCandidates(accountId: accountId)
        }
        .confirmationDialog(
            "Unsubscribe from \(selected.count) sender\(selected.count == 1 ? "" : "s")?",
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            // Cancel is listed first and is the cancellation role, so Escape and Return both back
            // out. Unsubscribing is an outbound request to a third party that the app cannot undo —
            // re-subscribing means going to the sender — so the safe choice has to be the easy one.
            Button("Cancel", role: .cancel) {}
            Button("Unsubscribe from \(selected.count)") {
                run()
            }
        } message: {
            Text(confirmationDetail)
        }
    }

    private var confirmationDetail: String {
        var lines = ["This stops about \(selectedYearlyVolume) emails a year."]
        for c in selectedWithCollateral {
            var loss = "\(c.senderEmail) also sends mail worth keeping"
            if !c.modelKeepSubjects.isEmpty {
                loss += " — \(c.modelKeepSubjects.joined(separator: ", "))"
            } else if c.mustKeepCount > 0 {
                loss += " — \(c.mustKeepCount) message\(c.mustKeepCount == 1 ? "" : "s") marked must-keep"
            }
            lines.append(loss + ".")
        }
        lines.append("Existing mail is not deleted. This cannot be undone from here.")
        return lines.joined(separator: "\n\n")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Subscriptions")
                    .font(.headline)
                Spacer()
                if !selected.isEmpty {
                    Text("\(selected.count) selected · ~\(selectedYearlyVolume)/year")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Unsubscribe…") { showConfirmation = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty || isRunning || accountId == nil)
            }
            // Ranked by forward flow, not by how much has piled up — unsubscribing deletes nothing,
            // it only stops what comes next, and those two orderings disagree.
            Text("Ranked by mail this would stop arriving. Ending a subscription does not delete anything you already have.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No sender in this account advertises an unsubscribe option.")
                .foregroundStyle(.secondary)
            Text("Only mail carrying a List-Unsubscribe header can be ended from here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ c: UnsubscribeCandidate) -> some View {
        let recommendation = c.recommendation()
        let selectable = recommendation == .unsubscribe || recommendation == .unsubscribeWithCollateral

        return HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { selected.contains(c.senderEmail) },
                set: { on in
                    if on { selected.insert(c.senderEmail) } else { selected.remove(c.senderEmail) }
                }
            ))
            .labelsHidden()
            .disabled(!selectable || isRunning)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(c.senderEmail)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if c.alreadyAttempted {
                        // A sender that kept writing after a successful unsubscribe is the one case
                        // where the app's own action demonstrably failed, so it is stated rather than
                        // hidden by removing the row.
                        Text("already tried")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                    }
                    if !c.supportsOneClick {
                        Text("needs a browser step")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("~\(Int(c.projectedYearlyVolume.rounded())) a year · \(c.storedVolume) stored\(c.modelCategory.map { " · model: \($0.displayName)" } ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // The cost of the decision, stated on the row. The model's keep list is the only
                // place some of this is recorded and it has never been shown to the user.
                if c.hasCollateral {
                    let detail = c.modelKeepSubjects.isEmpty
                        ? "\(c.mustKeepCount) message\(c.mustKeepCount == 1 ? "" : "s") here are must-keep"
                        : "you would also lose: \(c.modelKeepSubjects.joined(separator: ", "))"
                    Label(detail, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            Text(recommendation.displayName)
                .font(.caption2)
                .foregroundStyle(selectable ? .primary : .secondary)
        }
        .padding(.vertical, 3)
        .opacity(selectable ? 1 : 0.6)
    }

    private func run() {
        guard let accountId else { return }
        isRunning = true
        let targets = Array(selected)
        Task { @MainActor in
            await appState.unsubscribeFromAll(senderEmails: targets, accountId: accountId)
            selected = []
            isRunning = false
        }
    }
}
