import SwiftUI
import TriageCore

/// Executed action history, newest first, with per-batch undo.
///
/// This surface is what the confirmation dialog has always promised ("You can undo
/// this action from the History tab") — the undo logic existed in `BatchExecutor` from
/// the start but had no caller and no entry point in the UI.
struct HistoryView: View {
    @EnvironmentObject private var appState: AppState

    @State private var isLoading = false
    @State private var confirmingUndo: ActionLog?

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.actionHistory.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(appState.actionHistory) { action in
                        ActionHistoryRow(
                            action: action,
                            isBusy: appState.isExecuting,
                            onUndo: { confirmingUndo = action }
                        )
                    }
                }
                .listStyle(.inset)
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
        .alert("Undo this action?", isPresented: .constant(confirmingUndo != nil), presenting: confirmingUndo) { action in
            Button("Cancel", role: .cancel) { confirmingUndo = nil }
            Button("Undo") {
                let target = action
                confirmingUndo = nil
                Task { await appState.undo(action: target) }
            }
        } message: { action in
            Text(undoExplanation(for: action))
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "clock.arrow.circlepath")
            Text("History")
                .font(.headline)
            Spacer()
            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(isLoading)
        }
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No actions executed yet")
                .font(.title3)
            Text("Once you execute a plan or pending actions, each batch appears here and can be undone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func undoExplanation(for action: ActionLog) -> String {
        switch action.action {
        case .deleted:
            return """
            This will restore \(action.messageCount) emails from Trash back to your inbox.

            Gmail keeps trashed mail for 30 days — after that the restore will not find them.
            """
        case .archived:
            return "This will move \(action.messageCount) emails back into your inbox."
        default:
            return "This will reverse \(action.messageCount) changes."
        }
    }

    private func load() async {
        guard let accountId = appState.selectedAccount?.id else { return }
        isLoading = true
        defer { isLoading = false }
        await appState.loadActionHistory(accountId: accountId)
    }
}

// MARK: - Row

struct ActionHistoryRow: View {
    let action: ActionLog
    let isBusy: Bool
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(action.description)
                    .fontWeight(.medium)

                HStack(spacing: 6) {
                    Text(action.executedAt, format: .dateTime.day().month().year().hour().minute())
                    if action.isReversed, let reversedAt = action.reversedAt {
                        Text("• undone \(reversedAt, format: .dateTime.day().month().hour().minute())")
                            .foregroundStyle(.green)
                    } else if action.action == .deleted {
                        Text("• recoverable for 30 days")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if action.isReversed {
                Label("Undone", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if action.isReversible {
                Button("Undo", action: onUndo)
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
            } else {
                Text("Not reversible")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch action.action {
        case .deleted: return "trash"
        case .archived: return "archivebox"
        case .labeled: return "tag"
        case .unsubscribed: return "envelope.badge.shield.half.filled"
        case .skipped: return "minus.circle"
        }
    }

    private var tint: Color {
        if action.isReversed { return .secondary }
        switch action.action {
        case .deleted: return .red
        case .archived: return .blue
        default: return .secondary
        }
    }
}
