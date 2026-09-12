import SwiftUI
import TriageCore

/// Ratify the model's reads in bulk, with exceptions.
///
/// Built after measuring what "review" actually contained once every message had been read
/// individually: 101 of 103 were "the model read this and judged it disposable", held only
/// because the provider had not independently agreed. That is not 103 questions. It is one
/// question — do you accept these reads — with the right to pull individual messages out.
///
/// So the primary action is a bulk accept per sender, and per-message toggles are the
/// exception mechanism rather than the main path. A screen that made the user click 103 times
/// to express one judgement would repeat the mistake this app already made by showing a flat
/// review queue instead of a ranked list of decisions.
struct ReviewInboxView: View {
    @EnvironmentObject private var appState: AppState

    @State private var selection: Set<String> = []
    @State private var expandedSenders: Set<String> = []

    // Owned by AppState rather than the view: the same data drives the tier counts elsewhere,
    // and the view has no business holding a database handle.
    private var emails: [EmailMetadata] { appState.reviewQueue }
    private var isLoading: Bool { appState.isLoadingReviewQueue }
    private var status: String? { appState.reviewStatus }

    private var accountId: Int64? { appState.settingsTarget?.id }

    private var bySender: [(sender: String, emails: [EmailMetadata])] {
        Dictionary(grouping: emails, by: \.senderEmail)
            .map { (sender: $0.key, emails: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.emails.count > $1.emails.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if emails.isEmpty {
                empty
            } else {
                list
                Divider()
                footer
            }
        }
        // Keyed on the account list as well as the target id. Keying on the id alone was
        // fragile: the id is derived from `appState.accounts`, which is loaded asynchronously
        // by a parent view, so this screen can appear while it is still empty — and if the id
        // is nil at that moment the load returns early and nothing re-triggers it.
        .task(id: "\(appState.accounts.count)-\(accountId ?? -1)") { await reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Review")
                    .font(.title2.weight(.semibold))
                // Named explicitly. These screens are account-scoped and used to say nothing
                // about which account, so an empty screen was indistinguishable from a broken
                // one — which is exactly how this screen was first reported.
                if let account = appState.settingsTarget {
                    Text(account.email)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !emails.isEmpty {
                    Text("\(emails.count) awaiting your decision")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("The model has already read each of these and given its reasoning. Accept its judgement in bulk, or pull out anything you want to keep.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            // Self-reporting state. This screen has now shown nothing twice while the database
            // held matching rows, and both explanations were guesses that cost a round trip.
            // An account-scoped screen that cannot say which account it queried, or whether the
            // query ran at all, is unfixable from a bug report — so it says.
            Text(diagnostic)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .padding(20)
    }

    private var diagnostic: String {
        let target = appState.settingsTarget
            .map { "\($0.email) (id \($0.id.map(String.init) ?? "nil"))" } ?? "none"
        let counts = appState.categorizedCountsByAccount
            .map { "\($0.key):\($0.value)" }
            .sorted()
            .joined(separator: " ")
        return "accounts loaded: \(appState.accounts.count) · target: \(target)"
            + " · categorized per account: [\(counts.isEmpty ? "not loaded" : counts)]"
            + " · queue: \(emails.count) · loading: \(isLoading)"
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("Nothing awaiting review")
                .font(.headline)

            // An empty state has to distinguish "finished" from "this account has no scanned
            // mail", because those look identical and mean opposite things.
            if let account = appState.settingsTarget,
               let id = account.id,
               (appState.categorizedCountsByAccount[id] ?? 0) == 0 {
                Text("\(account.email) has no categorized mail yet — scan it, or pick another account in the sidebar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            } else {
                Text("Every email has been decided — by you, by a rule, or by the model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(bySender, id: \.sender) { group in
                    senderSection(group.sender, group.emails)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private func senderSection(_ sender: String, _ mail: [EmailMetadata]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    if expandedSenders.contains(sender) {
                        expandedSenders.remove(sender)
                    } else {
                        expandedSenders.insert(sender)
                    }
                } label: {
                    Image(systemName: expandedSenders.contains(sender)
                          ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)

                Text(sender)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text("\(mail.count)")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                    .foregroundStyle(.secondary)

                Spacer()

                // The primary action, per sender: this is the unit the decision is actually
                // made in. 54 emails from one rail operator is one judgement, not 54.
                Button("Delete all \(mail.count)") {
                    Task { await decide(.dispose, ids: mail.map(\.messageId)) }
                }
                .font(.caption)
                Button("Keep all") {
                    Task { await decide(.keep, ids: mail.map(\.messageId)) }
                }
                .font(.caption)
            }
            .padding(.vertical, 4)

            if expandedSenders.contains(sender) {
                ForEach(mail, id: \.messageId) { email in
                    messageRow(email)
                }
                .padding(.leading, 22)
            }
        }
        .padding(.bottom, 6)
    }

    private func messageRow(_ email: EmailMetadata) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle(
                isOn: Binding(
                    get: { selection.contains(email.messageId) },
                    set: { on in
                        if on { selection.insert(email.messageId) }
                        else { selection.remove(email.messageId) }
                    }
                )
            ) { EmptyView() }
                .labelsHidden()

            VStack(alignment: .leading, spacing: 1) {
                Text(email.subject)
                    .font(.caption)
                    .lineLimit(1)
                    .textSelection(.enabled)
                // The model's own words, so accepting in bulk is still an informed act rather
                // than a leap of faith.
                if let reason = email.categoryReason {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(email.date, style: .date)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 1)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if selection.isEmpty {
                // The global action, stated with its exact scope so it cannot be pressed
                // without knowing what it covers.
                Button("Accept the model's read on all \(emails.count)") {
                    Task { await decide(.dispose, ids: emails.map(\.messageId)) }
                }
                .buttonStyle(.borderedProminent)
                Text("Moves them to the deletable tier. Deleting only ever moves mail to Gmail's trash, recoverable for 30 days.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(selection.count) selected")
                    .font(.caption)
                Button("Keep these") {
                    Task { await decide(.keep, ids: Array(selection)) }
                }
                .buttonStyle(.borderedProminent)
                Button("Delete these") {
                    Task { await decide(.dispose, ids: Array(selection)) }
                }
                Button("Clear") { selection.removeAll() }
                    .buttonStyle(.borderless)
            }
            Spacer()
        }
        .padding(20)
    }

    private func decide(_ decision: DisposalDecision, ids: [String]) async {
        guard let accountId else { return }
        selection.subtract(ids)
        await appState.recordDisposal(decision, messageIds: ids, accountId: accountId)
        expandVisibleWhenSmall()
    }

    private func reload() async {
        guard let accountId else { return }
        await appState.loadReviewQueue(accountId: accountId)
        expandVisibleWhenSmall()
    }

    /// Expanded automatically when there is little left, so a small remainder does not need a
    /// click before it can be seen at all.
    private func expandVisibleWhenSmall() {
        if emails.count <= 20 {
            expandedSenders = Set(emails.map(\.senderEmail))
        }
    }
}
