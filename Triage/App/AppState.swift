import SwiftUI
import TriageCore

@MainActor
final class AppState: ObservableObject {
    /// Which surface the detail column shows.
    ///
    /// Account selection is a separate axis (the sidebar's `List` selection is typed to
    /// `EmailAccount`), so the chosen view is tracked here rather than folded into it.
    enum DetailRoute: Hashable {
        case overview
        case history
    }

    @Published var detailRoute: DetailRoute = .overview
    @Published var accounts: [EmailAccount] = []
    @Published var scanProgress: ScanProgress?
    @Published var isScanning = false
    @Published var selectedAccount: EmailAccount?
    @Published var accountStats: AccountStats?
    @Published var actionPlan: ActionPlan?
    @Published var isExecuting = false
    /// Number of addresses currently protected. Surfaced so a user can see at a glance
    /// whether contact detection has actually run — a zero here means every "Protected"
    /// count in the UI is zero too.
    @Published var knownContactCount = 0
    @Published var isRefreshingContacts = false
    /// Live progress while an action plan runs. Nil when idle.
    @Published var executionProgress: ExecutionProgress?
    @Published var actionHistory: [ActionLog] = []
    @Published var lastExecutionError: String?

    private let database: AppDatabase
    private let contactDetector: ContactDetector
    private var gmailService: GmailService?
    private var batchExecutor: BatchExecutor?

    init() {
        do {
            let db = try AppDatabase.shared()
            self.database = db
            self.contactDetector = ContactDetector(database: db)
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }
    }

    func loadAccounts() async {
        do {
            accounts = try await database.fetchAllAccounts()
        } catch {
            print("Failed to load accounts: \(error)")
        }
    }

    func startGmailScan(for account: EmailAccount) async {
        guard !isScanning else { return }
        isScanning = true
        scanProgress = ScanProgress(total: 0, fetched: 0, status: .connecting)

        defer { isScanning = false }

        do {
            // Ensure Gmail service is configured
            if gmailService == nil {
                let authService = GmailAuthService(clientId: Secrets.gmailClientId)
                let tokens = try await authService.getValidTokens()
                configureGmail(with: tokens)
            }

            guard let service = gmailService else {
                scanProgress?.status = .failed("Gmail service not configured. Please reconnect your account.")
                return
            }

            guard let accountId = account.id else {
                scanProgress?.status = .failed("Invalid account.")
                return
            }

            let stream = await service.fetchAllMetadata(
                accountId: accountId,
                lastHistoryId: account.lastHistoryId,
                incremental: account.lastHistoryId != nil
            )

            for try await progress in stream {
                scanProgress = progress
            }

            scanProgress?.status = .completed

            // Build the contact list BEFORE categorizing. Without this the engine's
            // highest-priority rule (known contact -> personal/protected) cannot fire,
            // so nothing is ever protected from the action plan.
            await refreshContacts(for: account, using: service)

            // Auto-categorize after scan
            await categorizeEmails(accountId: accountId)
        } catch {
            scanProgress?.status = .failed(error.localizedDescription)
        }
    }

    /// Detect and persist the account's real correspondents.
    ///
    /// Failure here is non-fatal but IS surfaced: falling back to an empty contact set
    /// silently disables the protected tier, which is exactly the kind of degradation
    /// that should never be quiet.
    func refreshContacts(for account: EmailAccount, using service: GmailService) async {
        guard let accountId = account.id else { return }
        isRefreshingContacts = true
        defer { isRefreshingContacts = false }

        do {
            let sentContacts = try await service.fetchSentMailContacts(
                accountId: accountId,
                ownAddress: account.email
            )
            let contacts = try await contactDetector.refreshAndPersist(
                accountId: accountId,
                sentMailContacts: sentContacts
            )
            knownContactCount = contacts.count
        } catch {
            // Fall back to whatever was persisted previously rather than an empty set.
            let fallback = (try? await contactDetector.loadPersistedContacts(accountId: accountId)) ?? []
            knownContactCount = fallback.count
            scanProgress?.status = .failed(
                "Contact detection failed (\(error.localizedDescription)). "
                + "Using \(fallback.count) previously-saved contacts — review the plan carefully."
            )
        }
    }

    func categorizeEmails(accountId: Int64) async {
        do {
            let uncategorized = try await database.fetchUncategorizedEmails(accountId: accountId)
            guard !uncategorized.isEmpty else {
                accountStats = try await database.accountStats(accountId: accountId)
                return
            }

            // Load the persisted contact set. Constructing RuleBasedEngine() without
            // this leaves knownContacts empty, which silently disables the only rule
            // that assigns the protected tier.
            let contacts = try await contactDetector.loadPersistedContacts(accountId: accountId)
            knownContactCount = contacts.count

            let engine = RuleBasedEngine(knownContacts: contacts)
            let results = try await engine.categorize(emails: uncategorized)
            try await database.updateCategories(results, accountId: accountId)

            // Refresh stats
            accountStats = try await database.accountStats(accountId: accountId)
        } catch {
            print("Categorization failed: \(error)")
        }
    }

    /// Re-run categorization over every email, discarding cached decisions.
    /// Needed after the contact list changes, since previously-categorized mail
    /// was judged against the older (possibly empty) contact set.
    func recategorizeAll(accountId: Int64) async {
        do {
            let contacts = try await contactDetector.loadPersistedContacts(accountId: accountId)
            knownContactCount = contacts.count

            let all = try await database.fetchEmails(accountId: accountId, limit: 50000, offset: 0)
            guard !all.isEmpty else { return }

            let engine = RuleBasedEngine(knownContacts: contacts)
            let results = try await engine.categorize(emails: all)
            try await database.updateCategories(results, accountId: accountId)
            accountStats = try await database.accountStats(accountId: accountId)
        } catch {
            print("Recategorization failed: \(error)")
        }
    }

    /// Pin an address so its mail is never auto-actioned, then re-apply categorization.
    func pinContact(email: String, accountId: Int64) async {
        do {
            try await database.addManualContact(email: email, accountId: accountId)
            await recategorizeAll(accountId: accountId)
        } catch {
            print("Failed to pin contact: \(error)")
        }
    }

    func loadContactCount(accountId: Int64) async {
        let contacts = (try? await contactDetector.loadPersistedContacts(accountId: accountId)) ?? []
        knownContactCount = contacts.count
    }

    func generatePlan() async {
        guard let account = selectedAccount, let accountId = account.id else { return }
        do {
            let emails = try await database.fetchEmails(accountId: accountId, limit: 50000, offset: 0)
            let planner = ActionPlanner()
            actionPlan = planner.generatePlan(emails: emails, accountId: accountId)
        } catch {
            print("Plan generation failed: \(error)")
        }
    }

    func cancelExecution() async {
        await batchExecutor?.cancel()
    }

    // MARK: - Plan Execution

    /// Execute an approved action plan against the provider, streaming progress.
    ///
    /// This is the path that `ActionPlanView` previously left as a stub, so the whole
    /// generate -> approve -> confirm flow did nothing at all.
    func executePlan(_ plan: ActionPlan) async {
        guard let executor = batchExecutor, let account = selectedAccount else {
            lastExecutionError = "No account connected. Reconnect and rescan before executing."
            return
        }
        guard plan.totalApproved > 0 else {
            lastExecutionError = "Nothing approved in this plan."
            return
        }

        isExecuting = true
        lastExecutionError = nil
        defer {
            isExecuting = false
            executionProgress = nil
        }

        do {
            let stream = await executor.execute(plan: plan, provider: account.provider)
            for try await progress in stream {
                executionProgress = progress
                if case .failed(let message) = progress.status {
                    lastExecutionError = message
                }
            }

            if let accountId = account.id {
                accountStats = try await database.accountStats(accountId: accountId)
                await loadActionHistory(accountId: accountId)
                // The executed mail has left the working set, so the old plan is stale.
                actionPlan = nil
            }
        } catch {
            lastExecutionError = error.localizedDescription
        }
    }

    // MARK: - History & Undo

    func loadActionHistory(accountId: Int64) async {
        do {
            actionHistory = try await database.fetchActionHistory(accountId: accountId)
        } catch {
            print("Failed to load action history: \(error)")
        }
    }

    /// Reverse a previously-executed batch.
    ///
    /// Note the provider comes from the selected account rather than a default — a
    /// Yahoo action reversed through the Gmail branch would fail or hit the wrong API.
    func undo(action: ActionLog) async {
        guard let executor = batchExecutor, let account = selectedAccount, let actionId = action.id else {
            lastExecutionError = "No account connected — cannot undo."
            return
        }

        isExecuting = true
        lastExecutionError = nil
        defer { isExecuting = false }

        do {
            try await executor.undoAction(actionId: actionId, provider: account.provider)
            if let accountId = account.id {
                accountStats = try await database.accountStats(accountId: accountId)
                await loadActionHistory(accountId: accountId)
            }
        } catch {
            lastExecutionError = "Undo failed: \(error.localizedDescription)"
        }
    }

    func fetchEmails(accountId: Int64, category: EmailCategory) async throws -> [EmailMetadata] {
        try await database.fetchEmails(accountId: accountId, category: category, limit: 500)
    }

    func fetchEmailsByTier(accountId: Int64, tier: SafetyTier) async throws -> [EmailMetadata] {
        try await database.fetchEmailsByTier(accountId: accountId, tier: tier, limit: 500)
    }

    /// The review queue, least-confident first — the correct order for human review.
    func fetchEmailsForReview(accountId: Int64) async throws -> [EmailMetadata] {
        try await database.fetchEmailsForReview(accountId: accountId)
    }

    func findSimilarBySubject(accountId: Int64, subject: String) async throws -> [EmailMetadata] {
        try await database.findSimilarBySubject(accountId: accountId, subject: subject)
    }

    func markEmailsForDeletion(messageIds: [String], accountId: Int64) async throws {
        try await database.markEmailsActioned(messageIds: messageIds, accountId: accountId, action: .deleted)
    }

    func markEmailsForArchive(messageIds: [String], accountId: Int64) async throws {
        try await database.markEmailsActioned(messageIds: messageIds, accountId: accountId, action: .archived)
    }

    func fetchMarkedEmails(accountId: Int64) async throws -> [EmailMetadata] {
        try await database.fetchMarkedEmails(accountId: accountId)
    }

    func clearMarkedEmails(messageIds: [String], accountId: Int64) async throws {
        try await database.markEmailsActioned(messageIds: messageIds, accountId: accountId, action: nil)
    }

    func deleteAccount(_ account: EmailAccount) async {
        do {
            if let accountId = account.id {
                try await database.deleteAccount(accountId: accountId)
            }
            accounts.removeAll { $0.id == account.id }
            if selectedAccount?.id == account.id {
                selectedAccount = nil
                accountStats = nil
                actionPlan = nil
                gmailService = nil
                batchExecutor = nil
            }
            // Clear stored OAuth tokens
            let authService = GmailAuthService(clientId: Secrets.gmailClientId)
            try? authService.signOut()
        } catch {
            print("Failed to delete account: \(error)")
        }
    }

    func executePendingActions(emails: [EmailMetadata]) async throws {
        guard let executor = batchExecutor, let account = selectedAccount else {
            throw NSError(domain: "Triage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Gmail service not configured"])
        }
        isExecuting = true
        defer { isExecuting = false }

        let toDelete = emails.filter { $0.actionTaken == .deleted }
        let toArchive = emails.filter { $0.actionTaken == .archived }

        // Build a minimal action plan from marked emails
        var planItems: [ActionPlanItem] = []

        if !toDelete.isEmpty {
            let entries = toDelete.map { ActionPlanEntry(messageId: $0.messageId, sender: $0.sender, senderEmail: $0.senderEmail, subject: $0.subject, date: $0.date) }
            planItems.append(ActionPlanItem(
                id: "manual-delete",
                category: .unknown,
                action: .deleted,
                entries: entries,
                isApproved: true
            ))
        }

        if !toArchive.isEmpty {
            let entries = toArchive.map { ActionPlanEntry(messageId: $0.messageId, sender: $0.sender, senderEmail: $0.senderEmail, subject: $0.subject, date: $0.date) }
            planItems.append(ActionPlanItem(
                id: "manual-archive",
                category: .unknown,
                action: .archived,
                entries: entries,
                isApproved: true
            ))
        }

        let plan = ActionPlan(
            accountId: account.id!,
            generatedAt: Date(),
            items: planItems,
            summary: ActionPlanSummary(
                totalEmails: emails.count,
                toArchive: toArchive.count,
                toDelete: toDelete.count
            )
        )

        let stream = await executor.execute(plan: plan, provider: account.provider)
        for try await progress in stream {
            executionProgress = progress
        }
        executionProgress = nil

        // Deleted rows are deliberately NOT removed from the local database.
        // BatchExecutor marks them executed instead, which keeps them out of the
        // working views while leaving the batch undoable — deleting the rows made
        // undo unable to restore local state.
        if let accountId = account.id {
            accountStats = try await database.accountStats(accountId: accountId)
            await loadActionHistory(accountId: accountId)
        }
    }

    func refreshStats(accountId: Int64) async throws -> AccountStats {
        try await database.accountStats(accountId: accountId)
    }

    func configureGmail(with authTokens: OAuthTokens) {
        let rateLimiter = RateLimiter(maxRequestsPerSecond: 45)
        let retryPolicy = RetryPolicy()
        let client = GmailAPIClient(
            tokens: authTokens,
            rateLimiter: rateLimiter,
            retryPolicy: retryPolicy
        )
        self.gmailService = GmailService(client: client, database: database)
        self.batchExecutor = BatchExecutor(gmailClient: client, database: database)
    }

    func addGmailAccount(tokens: OAuthTokens) async {
        do {
            // Fetch the user's email from Gmail API
            let rateLimiter = RateLimiter(maxRequestsPerSecond: 45)
            let retryPolicy = RetryPolicy()
            let client = GmailAPIClient(
                tokens: tokens,
                rateLimiter: rateLimiter,
                retryPolicy: retryPolicy
            )
            let profile = try await client.getProfile()

            var account = EmailAccount(
                email: profile.emailAddress,
                provider: .gmail,
                displayName: profile.emailAddress,
                createdAt: Date()
            )
            try await database.saveAccount(&account)
            accounts.append(account)
            selectedAccount = account
        } catch {
            print("Failed to add Gmail account: \(error)")
        }
    }
}
