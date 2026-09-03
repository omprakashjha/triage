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
                            }
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
        HStack {
            if let progress = executionProgress {
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

            if isExecuting {
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

    private var totalApproved: Int {
        items.filter(\.isApproved).reduce(0) { $0 + $1.emailCount }
    }

    private var approvedArchiveCount: Int {
        items.filter { $0.isApproved && $0.action == .archived }.reduce(0) { $0 + $1.emailCount }
    }

    private var approvedDeleteCount: Int {
        items.filter { $0.isApproved && $0.action == .deleted }.reduce(0) { $0 + $1.emailCount }
    }

    // MARK: - Execution

    private func executeApprovedPlan() async {
        showConfirmation = false
        isExecuting = true
        defer { isExecuting = false }

        // Execution would be wired through AppState → BatchExecutor
        // For now, this demonstrates the UI flow
    }
}

// MARK: - Action Plan Item Row

struct ActionPlanItemRow: View {
    let item: ActionPlanItem
    let isExpanded: Bool
    let onToggleApproval: () -> Void
    let onToggleExpand: () -> Void

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
                    Text("\(item.emailCount) emails from \(item.senderBreakdown.count) senders")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    ForEach(item.senderBreakdown.prefix(20), id: \.email) { sender in
                        HStack {
                            Text(sender.sender)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text("\(sender.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 40)
                    }

                    if item.senderBreakdown.count > 20 {
                        Text("and \(item.senderBreakdown.count - 20) more senders...")
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
        plan.items.filter { $0.isApproved && $0.action == .archived }.reduce(0) { $0 + $1.emailCount }
    }

    private var deleteCount: Int {
        plan.items.filter { $0.isApproved && $0.action == .deleted }.reduce(0) { $0 + $1.emailCount }
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
