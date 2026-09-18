import SwiftUI
import TriageCore

/// Main view for reviewing and executing an action plan
struct ActionPlanView: View {
    @EnvironmentObject private var appState: AppState
    let plan: ActionPlan

    @State private var items: [ActionPlanItem]
    @State private var isExecuting = false
    @State private var showConfirmation = false
    @State private var executionProgress: ExecutionProgress?
    @State private var expandedItem: String?

    init(plan: ActionPlan) {
        self.plan = plan
        self._items = State(initialValue: plan.items)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Summary header
            planSummaryHeader

            Divider()

            // Action items list
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        ActionPlanItemRow(
                            item: item,
                            isExpanded: expandedItem == item.id,
                            onToggleApproval: { items[index].isApproved.toggle() },
                            onToggleExpand: {
                                expandedItem = expandedItem == item.id ? nil : item.id
                            },
                            excludedSenders: excludedSenders(for: item),
                            onToggleSender: { sender in toggleSender(sender, in: index) }
                        )
                    }
                }
                .padding()
            }

            Divider()

            // Execute footer
            executeFooter
        }
        .sheet(isPresented: $showConfirmation) {
            ConfirmExecutionView(
                plan: currentPlan,
                onConfirm: { Task { await executeApprovedPlan() } },
                onCancel: { showConfirmation = false }
            )
        }
    }

    // MARK: - Summary Header

    private var planSummaryHeader: some View {
        HStack(spacing: 24) {
            StatBox(value: plan.summary.totalEmails, label: "Total", color: .primary)
            StatBox(value: approvedArchiveCount, label: "Archive", color: .blue)
            StatBox(value: approvedDeleteCount, label: "Delete", color: .red)
            StatBox(value: plan.summary.protectedCount, label: "Protected", color: .green)
            Spacer()
        }
        .padding()
        .background(.bar)
    }

    // MARK: - Execute Footer

    private var executeFooter: some View {
        VStack(spacing: 6) {
            if let error = appState.lastExecutionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                if let progress = appState.executionProgress {
                    ProgressView(value: progress.progress) {
                        Text(progress.currentBatch)
                            .font(.caption)
                    }
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 300)

                    Text("\(progress.completedActions)/\(progress.totalActions)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if appState.isExecuting {
                    Button("Cancel") {
                        Task { await appState.cancelExecution() }
                    }
                    .buttonStyle(.bordered)
                } else {
                    Text("\(totalApproved) emails will be affected")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Execute Plan") {
                        showConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(totalApproved == 0)
                }
            }
        }
        .padding()
        .background(.bar)
    }

    // MARK: - Computed

    private var currentPlan: ActionPlan {
        ActionPlan(
            accountId: plan.accountId,
            generatedAt: plan.generatedAt,
            items: items,
            summary: plan.summary
        )
    }

    /// Sender addresses excluded from a given item, lowercased.
    ///
    /// Derived from the item's excluded message ids rather than stored separately, so the two can
    /// never disagree — the ids are what the executor reads, and a parallel set of sender names would
    /// be one more thing to keep in sync.
    private func excludedSenders(for item: ActionPlanItem) -> Set<String> {
        guard !item.excludedMessageIds.isEmpty else { return [] }
        var excluded: Set<String> = []
        for entry in item.entries where item.excludedMessageIds.contains(entry.messageId) {
            excluded.insert(entry.senderEmail.lowercased())
        }
        return excluded
    }

    /// Include or exclude every message from one sender within one item.
    private func toggleSender(_ senderEmail: String, in index: Int) {
        let sender = senderEmail.lowercased()
        let ids = items[index].entries
            .filter { $0.senderEmail.lowercased() == sender }
            .map(\.messageId)
        guard !ids.isEmpty else { return }

        if items[index].excludedMessageIds.isSuperset(of: ids) {
            items[index].excludedMessageIds.subtract(ids)
        } else {
            items[index].excludedMessageIds.formUnion(ids)
        }
    }

    private var totalApproved: Int {
        items.filter(\.isApproved).reduce(0) { $0 + $1.approvedCount }
    }

    private var approvedArchiveCount: Int {
        items.filter { $0.isApproved && $0.action == .archived }.reduce(0) { $0 + $1.approvedCount }
    }

    private var approvedDeleteCount: Int {
        items.filter { $0.isApproved && $0.action == .deleted }.reduce(0) { $0 + $1.approvedCount }
    }

    // MARK: - Execution

    private func executeApprovedPlan() async {
        showConfirmation = false
        isExecuting = true
        defer { isExecuting = false }

        // Execute the plan as the user actually approved it, not as originally
        // generated — `items` carries their per-item approval toggles.
        await appState.executePlan(currentPlan)
    }
}

// MARK: - Action Plan Item Row

struct ActionPlanItemRow: View {
    let item: ActionPlanItem
    let isExpanded: Bool
    let onToggleApproval: () -> Void
    let onToggleExpand: () -> Void
    /// Sender addresses currently excluded from this item, lowercased.
    let excludedSenders: Set<String>
    /// Toggle one sender in or out of this run.
    let onToggleSender: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Main row
            HStack {
                Toggle("", isOn: Binding(
                    get: { item.isApproved },
                    set: { _ in onToggleApproval() }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()

                Image(systemName: item.category.iconName)
                    .foregroundStyle(colorForAction)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.reason)
                        .font(.body)
                    // States the count that will actually be acted on. Showing only the item total
                    // while some senders are excluded would misreport what pressing execute does.
                    if item.approvedCount != item.emailCount {
                        Text("\(item.approvedCount) of \(item.emailCount) emails · \(item.senderBreakdown.count) senders, some excluded")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text("\(item.emailCount) emails from \(item.senderBreakdown.count) senders")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                actionBadge

                Button {
                    onToggleExpand()
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)

            // Expanded sender breakdown
            if isExpanded {
                Divider()
                    .padding(.leading, 40)

                VStack(spacing: 4) {
                    // Per-sender inclusion. The smallest thing this app could previously execute was
                    // a whole category, so its first ever deletion would have been dozens of
                    // messages at once on a path that had never run. One sender at a time makes a
                    // rehearsal possible: act, check Gmail, undo, check again.
                    Text("Untick a sender to leave it out of this run.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 40)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(item.senderBreakdown.prefix(20), id: \.email) { sender in
                        HStack {
                            Toggle("", isOn: Binding(
                                get: { !excludedSenders.contains(sender.email.lowercased()) },
                                set: { _ in onToggleSender(sender.email) }
                            ))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .disabled(!item.isApproved)

                            Text(sender.sender)
                                .font(.caption)
                                .lineLimit(1)
                                .foregroundStyle(
                                    excludedSenders.contains(sender.email.lowercased())
                                        ? .secondary : .primary
                                )
                            Spacer()
                            Text("\(sender.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 40)
                    }

                    if item.senderBreakdown.count > 20 {
                        // Says plainly that the unticked senders below are still included, rather
                        // than letting a truncated list imply the whole set is visible.
                        Text("and \(item.senderBreakdown.count - 20) more senders, all included")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 40)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
    }

    private var colorForAction: Color {
        switch item.action {
        case .deleted: return .red
        case .archived: return .blue
        default: return .secondary
        }
    }

    private var actionBadge: some View {
        Text(item.action == .deleted ? "DELETE" : "ARCHIVE")
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(item.action == .deleted ? Color.red.opacity(0.15) : Color.blue.opacity(0.15))
            )
            .foregroundStyle(item.action == .deleted ? .red : .blue)
    }
}

// MARK: - Confirm Execution Sheet

struct ConfirmExecutionView: View {
    let plan: ActionPlan
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)

            Text("Confirm Execution")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                if archiveCount > 0 {
                    Label("Archive \(archiveCount) emails", systemImage: "archivebox")
                }
                if deleteCount > 0 {
                    Label("Delete \(deleteCount) emails", systemImage: "trash")
                        .foregroundStyle(.red)
                }
                Label("\(plan.summary.protectedCount) emails protected (untouched)", systemImage: "shield")
                    .foregroundStyle(.green)
            }
            .font(.body)

            Text("You can undo this action from the History tab.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Cancel") { onCancel() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape)

                Button("Execute") { onConfirm() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(.return)
            }
        }
        .padding(30)
        .frame(width: 400)
    }

    private var archiveCount: Int {
        plan.items.filter { $0.isApproved && $0.action == .archived }.reduce(0) { $0 + $1.approvedCount }
    }

    private var deleteCount: Int {
        plan.items.filter { $0.isApproved && $0.action == .deleted }.reduce(0) { $0 + $1.approvedCount }
    }
}

// MARK: - Stat Box

struct StatBox: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
