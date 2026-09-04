import Foundation

/// Progress update during batch execution
public struct ExecutionProgress: Sendable {
    public let totalActions: Int
    public let completedActions: Int
    public let currentBatch: String  // Description of current batch
    public let status: ExecutionStatus

    public var progress: Double {
        guard totalActions > 0 else { return 0 }
        return Double(completedActions) / Double(totalActions)
    }
}

public enum ExecutionStatus: Sendable {
    case preparing
    case executing
    case completed
    case failed(String)
    case cancelled
}

/// Executes an action plan against Gmail and Yahoo APIs with rate limiting and undo logging
public actor BatchExecutor {
    private let gmailClient: GmailAPIClient?
    private let imapClient: IMAPClient?
    private let database: AppDatabase
    private var isCancelled: Bool = false

    public init(
        gmailClient: GmailAPIClient? = nil,
        imapClient: IMAPClient? = nil,
        database: AppDatabase
    ) {
        self.gmailClient = gmailClient
        self.imapClient = imapClient
        self.database = database
    }

    /// Cancel the current execution
    public func cancel() {
        isCancelled = true
    }

    /// Execute an approved action plan, yielding progress updates
    public func execute(plan: ActionPlan, provider: EmailProvider) -> AsyncThrowingStream<ExecutionProgress, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    self.isCancelled = false
                    let approvedItems = plan.items.filter(\.isApproved)
                    let totalActions = approvedItems.reduce(0) { $0 + $1.emailCount }

                    guard totalActions > 0 else {
                        continuation.yield(ExecutionProgress(
                            totalActions: 0, completedActions: 0,
                            currentBatch: "Nothing to do", status: .completed
                        ))
                        continuation.finish()
                        return
                    }

                    continuation.yield(ExecutionProgress(
                        totalActions: totalActions, completedActions: 0,
                        currentBatch: "Preparing...", status: .preparing
                    ))

                    var completed = 0

                    for item in approvedItems {
                        guard !self.isCancelled else {
                            continuation.yield(ExecutionProgress(
                                totalActions: totalActions, completedActions: completed,
                                currentBatch: "Cancelled", status: .cancelled
                            ))
                            continuation.finish()
                            return
                        }

                        let messageIds = item.entries.map(\.messageId)
                        let batchSize = provider == .gmail ? 100 : 50
                        let batches = stride(from: 0, to: messageIds.count, by: batchSize).map {
                            Array(messageIds[$0..<min($0 + batchSize, messageIds.count)])
                        }

                        // Track what actually landed. Logging the whole item up front
                        // would claim ids as executed even when the run was cancelled
                        // partway, making undo try to reverse work that never happened.
                        var executedIds: [String] = []

                        for batch in batches {
                            guard !self.isCancelled else { break }

                            let description = "\(item.action == .archived ? "Archiving" : "Deleting") \(item.category.displayName)"
                            continuation.yield(ExecutionProgress(
                                totalActions: totalActions, completedActions: completed,
                                currentBatch: description, status: .executing
                            ))

                            switch provider {
                            case .gmail:
                                try await self.executeGmailBatch(
                                    messageIds: batch,
                                    action: item.action
                                )
                            case .yahoo:
                                try await self.executeYahooBatch(
                                    messageIds: batch,
                                    action: item.action
                                )
                            }

                            executedIds.append(contentsOf: batch)
                            completed += batch.count
                        }

                        guard !executedIds.isEmpty else { continue }

                        // Log the action for undo
                        var actionLog = ActionLog(
                            accountId: plan.accountId,
                            action: item.action,
                            messageIds: executedIds,
                            messageCount: executedIds.count,
                            isReversible: true,
                            description: "\(item.action == .archived ? "Archived" : "Deleted") \(executedIds.count) \(item.category.displayName) emails"
                        )
                        try await self.database.logAction(&actionLog)

                        // Record as executed (not merely marked), so it leaves the
                        // working views while staying available for undo.
                        try await self.database.markEmailsExecuted(
                            messageIds: executedIds,
                            accountId: plan.accountId,
                            action: item.action
                        )
                    }

                    continuation.yield(ExecutionProgress(
                        totalActions: totalActions, completedActions: completed,
                        currentBatch: "Complete", status: .completed
                    ))
                    continuation.finish()

                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Gmail Execution

    private func executeGmailBatch(messageIds: [String], action: EmailAction) async throws {
        guard let client = gmailClient else {
            throw ExecutionError.noClient("Gmail client not configured")
        }

        for id in messageIds {
            switch action {
            case .archived:
                // Archive = remove INBOX label
                try await client.modifyMessage(id: id, removeLabels: ["INBOX"])
            case .deleted:
                // Delete = move to trash
                try await client.trashMessage(id: id)
            case .labeled, .unsubscribed, .skipped:
                break  // Not handled in batch execution
            }
        }
    }

    // MARK: - Yahoo Execution

    private func executeYahooBatch(messageIds: [String], action: EmailAction) async throws {
        guard let client = imapClient else {
            throw ExecutionError.noClient("Yahoo IMAP client not configured")
        }

        let uids = messageIds.compactMap { UInt32($0) }
        guard !uids.isEmpty else { return }

        let uidSet = uids.map(String.init).joined(separator: ",")

        switch action {
        case .archived:
            // Yahoo: move to Archive folder
            try await client.moveMessages(uids: uidSet, toMailbox: "Archive")
        case .deleted:
            // Yahoo: move to Trash
            try await client.moveMessages(uids: uidSet, toMailbox: "Trash")
        case .labeled, .unsubscribed, .skipped:
            break
        }

        // Rate limit: wait between batches for Yahoo
        try await Task.sleep(nanoseconds: 1_500_000_000)  // 1.5s
    }
}

// MARK: - Undo

extension BatchExecutor {
    /// Undo the most recent reversible action.
    ///
    /// `provider` is REQUIRED: it previously defaulted to `.gmail`, so undoing a Yahoo
    /// action silently took the Gmail branch and failed (or worse, addressed the wrong
    /// account's API).
    public func undoLastAction(provider: EmailProvider) async throws -> ActionLog? {
        let recentActions = try await database.fetchRecentActions(limit: 1)
        guard let lastAction = recentActions.first,
              lastAction.isReversible,
              !lastAction.isReversed else {
            return nil
        }

        try await reverseAction(lastAction, provider: provider)
        return lastAction
    }

    /// Undo a specific action by ID
    public func undoAction(actionId: Int64, provider: EmailProvider) async throws {
        guard let action = try await database.fetchAction(id: actionId),
              action.isReversible,
              !action.isReversed else {
            throw ExecutionError.cannotUndo("Action not found or not reversible")
        }

        try await reverseAction(action, provider: provider)
    }

    private func reverseAction(_ action: ActionLog, provider: EmailProvider) async throws {
        let messageIds = action.messageIds

        switch (provider, action.action) {
        case (.gmail, .archived):
            // Re-add INBOX label
            guard let client = gmailClient else { throw ExecutionError.noClient("Gmail") }
            for id in messageIds {
                try await client.modifyMessage(id: id, addLabels: ["INBOX"])
            }

        case (.gmail, .deleted):
            // Un-trash (Gmail keeps trashed messages for 30 days)
            guard let client = gmailClient else { throw ExecutionError.noClient("Gmail") }
            for id in messageIds {
                try await client.modifyMessage(id: id, removeLabels: ["TRASH"])
            }

        case (.yahoo, .archived):
            // Move back to INBOX from Archive
            guard let client = imapClient else { throw ExecutionError.noClient("Yahoo") }
            let uidSet = messageIds.joined(separator: ",")
            try await client.moveMessages(uids: uidSet, toMailbox: "INBOX")

        case (.yahoo, .deleted):
            // Move back to INBOX from Trash
            guard let client = imapClient else { throw ExecutionError.noClient("Yahoo") }
            let uidSet = messageIds.joined(separator: ",")
            try await client.moveMessages(uids: uidSet, toMailbox: "INBOX")

        default:
            throw ExecutionError.cannotUndo("Action type \(action.action) cannot be undone")
        }

        // Mark as reversed in database
        if let actionId = action.id {
            try await database.markActionReversed(actionId: actionId)
        }

        // Reset action status on emails
        try await database.markEmailsActioned(
            messageIds: messageIds,
            accountId: action.accountId,
            action: nil  // Clear action
        )
    }
}

// MARK: - Errors

public enum ExecutionError: LocalizedError, Sendable {
    case noClient(String)
    case cannotUndo(String)
    case partialFailure(succeeded: Int, failed: Int, lastError: String)

    public var errorDescription: String? {
        switch self {
        case .noClient(let msg): return "Client not available: \(msg)"
        case .cannotUndo(let msg): return "Cannot undo: \(msg)"
        case .partialFailure(let s, let f, let err):
            return "Partial failure: \(s) succeeded, \(f) failed. Last error: \(err)"
        }
    }
}
