import SwiftUI
import TriageCore

/// One row per sender, one decision each.
///
/// The reason this screen exists: a 10,000-message inbox comes from a few hundred
/// senders. Deciding 10,000 times is impossible; deciding 300 times is a coffee break.
/// Every column here comes from a SQL aggregate, so it stays cheap on a large mailbox.
struct SenderTriageView: View {
    @EnvironmentObject private var appState: AppState

    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .volume
    @State private var hideProtected = true
    @State private var deciding: SenderSummary?

    enum SortOrder: String, CaseIterable, Identifiable {
        case volume = "Most mail"
        case newest = "Most recent"
        case stalest = "Longest silent"
        case unread = "Most unread"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if appState.isLoadingSenders {
                ProgressView("Aggregating senders…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.senderSummaries.isEmpty {
                emptyState
            } else {
                table
            }

            if let error = appState.lastExecutionError {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: appState.selectedAccount?.id) {
            await load()
        }
        .sheet(item: $deciding) { summary in
            SenderDecisionSheet(summary: summary)
                .environmentObject(appState)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "person.2.badge.gearshape")
                Text("Senders")
                    .font(.headline)
                Text("\(filtered.count) of \(appState.senderSummaries.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Picker("Sort", selection: $sortOrder) {
                    ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(width: 150)

                Toggle("Hide protected", isOn: $hideProtected)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }

            TextField("Filter by sender or domain", text: $searchText)
                .textFieldStyle(.roundedBorder)

            if !appState.senderRules.isEmpty {
                Label(
                    "\(appState.senderRules.filter(\.isEnabled).count) standing rules apply automatically on each scan",
                    systemImage: "wand.and.stars"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No senders yet")
                .font(.title3)
            Text("Scan an account to build the sender list.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Table

    private var table: some View {
        Table(filtered) {
            TableColumn("Sender") { summary in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(summary.displayName)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        if summary.isProtected {
                            Image(systemName: "lock.shield.fill")
                                .foregroundStyle(.blue)
                                .font(.caption2)
                        }
                        if summary.hasUnsubscribeOption {
                            Image(systemName: "envelope.open")
                                .foregroundStyle(.secondary)
                                .font(.caption2)
                        }
                    }
                    Text(summary.senderEmail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .width(min: 180, ideal: 240)

            TableColumn("Mail") { summary in
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(summary.totalEmails)")
                        .fontWeight(.semibold)
                    if summary.unreadEmails > 0 {
                        Text("\(summary.unreadEmails) unread")
                            .font(.caption2)
                            .foregroundStyle(summary.isUnreadHeavy ? .orange : .secondary)
                    }
                }
            }
            .width(70)

            TableColumn("Cadence") { summary in
                if let interval = summary.averageIntervalDays {
                    Text(cadenceLabel(interval))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("once").font(.caption).foregroundStyle(.secondary)
                }
            }
            .width(90)

            TableColumn("Last seen") { summary in
                Text("\(summary.daysSinceLastSeen)d ago")
                    .font(.caption)
                    .foregroundStyle(summary.daysSinceLastSeen > 180 ? .secondary : .primary)
            }
            .width(80)

            TableColumn("Category") { summary in
                if let category = summary.dominantCategory {
                    Label(category.displayName, systemImage: category.iconName)
                        .font(.caption)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .width(110)

            TableColumn("Decide") { summary in
                if summary.isProtected {
                    Text("Protected")
                        .font(.caption)
                        .foregroundStyle(.blue)
                } else {
                    Button("Decide…") { deciding = summary }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            .width(80)
        }
    }

    // MARK: - Filtering

    private var filtered: [SenderSummary] {
        var result = appState.senderSummaries

        if hideProtected {
            result = result.filter { !$0.isProtected }
        }

        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            result = result.filter {
                $0.senderEmail.contains(needle) || $0.displayName.lowercased().contains(needle)
            }
        }

        switch sortOrder {
        case .volume: result.sort { $0.totalEmails > $1.totalEmails }
        case .newest: result.sort { $0.lastSeen > $1.lastSeen }
        case .stalest: result.sort { $0.lastSeen < $1.lastSeen }
        case .unread: result.sort { $0.unreadEmails > $1.unreadEmails }
        }

        return result
    }

    private func cadenceLabel(_ days: Double) -> String {
        if days < 1.5 { return "~daily" }
        if days < 10 { return String(format: "~%.0f days", days) }
        if days < 45 { return "~monthly" }
        return String(format: "~%.0f mo", days / 30)
    }

    private func load() async {
        guard let accountId = appState.selectedAccount?.id else { return }
        await appState.loadSenderSummaries(accountId: accountId)
    }
}

// MARK: - Decision Sheet

/// The single decision made per sender, with the consequence spelled out before it's taken.
struct SenderDecisionSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let summary: SenderSummary

    @State private var action: EmailAction = .archived
    @State private var persistAsRule = true
    @State private var ruleScope: RuleScope = .address
    @State private var keepNewest = 0

    private var affectedCount: Int {
        max(summary.totalEmails - keepNewest, 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.displayName)
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(summary.senderEmail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("\(summary.totalEmails) emails • \(summary.unreadEmails) unread • last \(summary.daysSinceLastSeen) days ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if summary.looksLikeSubscription {
                Label("Looks like a subscription rather than a person", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if summary.hasUnsubscribeOption {
                VStack(alignment: .leading, spacing: 6) {
                    // Unsubscribing is the only action here that reduces future mail
                    // rather than tidying past mail, so it gets its own affordance.
                    Button {
                        Task {
                            if let accountId = appState.selectedAccount?.id {
                                await appState.unsubscribe(from: summary, accountId: accountId)
                            }
                        }
                    } label: {
                        Label("Unsubscribe from this sender", systemImage: "envelope.badge.shield.half.filled")
                    }
                    .buttonStyle(.bordered)

                    if let message = appState.unsubscribeMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Divider()

            Picker("Action", selection: $action) {
                Text("Archive").tag(EmailAction.archived)
                Text("Delete").tag(EmailAction.deleted)
            }
            .pickerStyle(.segmented)

            Stepper(
                keepNewest == 0
                    ? "Apply to all \(summary.totalEmails)"
                    : "Keep newest \(keepNewest), apply to \(affectedCount)",
                value: $keepNewest,
                in: 0...min(summary.totalEmails, 50)
            )

            Toggle("Also do this automatically for future mail", isOn: $persistAsRule)

            if persistAsRule {
                Picker("Applies to", selection: $ruleScope) {
                    ForEach(RuleScope.allCases, id: \.self) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }
                .pickerStyle(.radioGroup)
                .padding(.leading, 20)
            }

            Divider()

            // Marking is reversible without touching the provider; execution is the
            // point of no return, so say plainly which one this button does.
            Label(
                "\(affectedCount) emails will be marked for \(action == .deleted ? "deletion" : "archive"). Nothing is sent to Gmail until you press Execute.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button("Protect this sender") {
                    Task {
                        if let accountId = appState.selectedAccount?.id {
                            await appState.protectSender(summary, accountId: accountId)
                        }
                        dismiss()
                    }
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Apply") {
                    Task {
                        if let accountId = appState.selectedAccount?.id {
                            await appState.decideSender(
                                summary,
                                action: action,
                                accountId: accountId,
                                persistAsRule: persistAsRule,
                                ruleScope: ruleScope,
                                keepNewest: keepNewest
                            )
                        }
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(action == .deleted ? .red : .accentColor)
                .disabled(affectedCount == 0)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
