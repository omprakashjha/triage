import SwiftUI
import TriageCore

@MainActor
final class AppState: ObservableObject {
    @Published var accounts: [EmailAccount] = []
    @Published var scanProgress: ScanProgress?
    @Published var isScanning = false
    @Published var selectedAccount: EmailAccount?
    @Published var accountStats: AccountStats?
    @Published var actionPlan: ActionPlan?
    @Published var isExecuting = false

    private let database: AppDatabase
    private var gmailService: GmailService?
    private var batchExecutor: BatchExecutor?

    init() {
        do {
            self.database = try AppDatabase.shared()
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

            // Auto-categorize after scan
            await categorizeEmails(accountId: accountId)
        } catch {
            scanProgress?.status = .failed(error.localizedDescription)
        }
    }

    func categorizeEmails(accountId: Int64) async {
        do {
            let uncategorized = try await database.fetchUncategorizedEmails(accountId: accountId)
            guard !uncategorized.isEmpty else {
                accountStats = try await database.accountStats(accountId: accountId)
                return
            }

            let engine = RuleBasedEngine()
            let results = try await engine.categorize(emails: uncategorized)
            try await database.updateCategories(results, accountId: accountId)

            // Refresh stats
            accountStats = try await database.accountStats(accountId: accountId)
        } catch {
            print("Categorization failed: \(error)")
        }
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

    func fetchEmails(accountId: Int64, category: EmailCategory) async throws -> [EmailMetadata] {
        try await database.fetchEmails(accountId: accountId, category: category, limit: 500)
    }

    func fetchEmailsByTier(accountId: Int64, tier: SafetyTier) async throws -> [EmailMetadata] {
        try await database.fetchEmailsByTier(accountId: accountId, tier: tier, limit: 500)
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
        for try await _ in stream {
            // Progress updates
        }

        // Remove deleted emails from local database
        let deletedIds = toDelete.map(\.messageId)
        if !deletedIds.isEmpty {
            try await database.removeEmails(messageIds: deletedIds, accountId: account.id!)
        }

        // Refresh stats
        accountStats = try await database.accountStats(accountId: account.id!)
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
