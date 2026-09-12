import SwiftUI
import AppKit
import TriageCore
import TriageBedrock

@MainActor
final class AppState: ObservableObject {
    /// Which surface the detail column shows.
    ///
    /// Account selection is a separate axis (the sidebar's `List` selection is typed to
    /// `EmailAccount`), so the chosen view is tracked here rather than folded into it.
    enum DetailRoute: Hashable {
        case overview
        case decide
        case review
        case senders
        case history
        case evaluation
        case settings
    }

    @Published var detailRoute: DetailRoute = .overview
    @Published var goldenLabels: [GoldenLabel] = []
    @Published var evaluationReport: EvaluationReport?
    @Published var isEvaluating = false
    @Published var exportedGoldenSetPath: String?
    /// Result of the last connection test, or an announced fallback. Never silent.
    @Published var aiStatusMessage: String?
    @Published var isTestingAI = false
    @Published var senderSummaries: [SenderSummary] = []
    @Published var senderRules: [SenderRule] = []
    @Published var settings: AccountSettings?
    @Published var isLoadingSenders = false
    /// Count of emails auto-marked by standing sender rules on the last scan.
    @Published var lastRuleMatchCount = 0
    @Published var unsubscribeMessage: String?
    /// Senders that kept sending after a successful unsubscribe.
    @Published var sendersIgnoringUnsubscribe: [String] = []
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
    @Published var isReconnecting = false
    /// Progress and outcome of the maintenance actions, so they are never silent.
    @Published var isRecategorizing = false
    @Published var maintenanceStatus: String?
    /// What the last AI pass actually did, counted rather than inferred.
    @Published var aiDiagnostics: String?
    /// The user's own corrections for the selected account, kept in memory because every
    /// categorization pass consults them.
    @Published var corrections: [UserCorrection] = []
    @Published var correctionStatus: String?
    /// Contact detection failing is a narrower problem than the scan failing, and is
    /// reported separately so the two are not confused.
    @Published var contactDetectionWarning: String?
    /// Live progress while an action plan runs. Nil when idle.
    @Published var executionProgress: ExecutionProgress?
    @Published var actionHistory: [ActionLog] = []
    @Published var lastExecutionError: String?

    private let database: AppDatabase
    private let contactDetector: ContactDetector
    private let unsubscribeService = UnsubscribeService()
    /// ONE auth service for the app's lifetime. Constructing a fresh one per call threw
    /// away its in-process token cache, so every scan re-authorised against the
    /// Keychain and produced another password prompt.
    let authService = GmailAuthService(clientId: Secrets.gmailClientId)
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

    /// The account a scan would act on.
    ///
    /// Falls back to the first account when the sidebar has no selection, so the toolbar
    /// action is never dead just because a selection was lost — which is exactly how the
    /// old in-view Scan button became unreachable.
    /// How much categorized mail each account holds, so a fallback can pick a useful one.
    @Published var categorizedCountsByAccount: [Int64: Int] = [:]

    /// The account with the most categorized mail — the one actually being worked on.
    ///
    /// `accounts.first` was the wrong fallback and produced a silent failure. Ordered by id,
    /// the first account here is one with 11,600 emails and none categorized, so every
    /// account-scoped screen defaulted to showing nothing and looked broken. "First by id" is
    /// arbitrary; "the one with data in it" is what the user meant.
    var primaryAccount: EmailAccount? {
        accounts.max { lhs, rhs in
            let l = lhs.id.flatMap { categorizedCountsByAccount[$0] } ?? 0
            let r = rhs.id.flatMap { categorizedCountsByAccount[$0] } ?? 0
            return l < r
        }
    }

    var scanTarget: EmailAccount? {
        selectedAccount ?? primaryAccount ?? accounts.first
    }

    /// Which account the account-scoped screens read and write.
    ///
    /// Same fallback, for the same reason. Settings gated its whole data load on an explicit
    /// sidebar selection, so with none it loaded nothing at all — the corrections list read
    /// "None yet" while 29 were stored, and the button that turns them into evaluation labels
    /// only renders when the list is non-empty, so it was unreachable. A screen the user
    /// navigated to deliberately should act on the obvious account rather than wait to be
    /// told which one.
    var settingsTarget: EmailAccount? {
        selectedAccount ?? primaryAccount ?? accounts.first
    }

    /// Scan whichever account is targeted, selecting it first so the UI agrees with what
    /// is being scanned.
    func scanSelectedAccount() async {
        guard let account = scanTarget else { return }
        if selectedAccount?.id != account.id {
            selectedAccount = account
        }
        await startGmailScan(for: account)
    }

    func loadAccounts() async {
        do {
            accounts = try await database.fetchAllAccounts()
            // Loaded here so the fallback account can be chosen by which one has data, rather
            // than by id order — which silently pointed every account-scoped screen at an
            // account holding 11,600 uncategorized emails and nothing to show.
            categorizedCountsByAccount = try await database.categorizedCountsByAccount()
        } catch {
            print("Failed to load accounts: \(error)")
        }
    }

    func startGmailScan(for account: EmailAccount) async {
        guard !isScanning else { return }
        isScanning = true
        contactDetectionWarning = nil
        scanProgress = ScanProgress(total: 0, fetched: 0, status: .connecting)

        defer { isScanning = false }

        do {
            // Ensure Gmail service is configured
            if gmailService == nil {
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

            await loadSettings(accountId: accountId)
            let scope = settings?.scanScope ?? .unreadOnly

            let stream = await service.fetchAllMetadata(
                accountId: accountId,
                lastHistoryId: account.lastHistoryId,
                incremental: account.lastHistoryId != nil,
                scope: scope
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

            // Standing sender rules cover new arrivals without asking again.
            await applySenderRules(accountId: accountId)
            await loadSenderSummaries(accountId: accountId)
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

            // Succeeding with nothing is its own problem and must not pass silently:
            // an empty contact set means the protected tier is empty, which is the
            // condition the whole safety model depends on NOT being true.
            if contacts.isEmpty {
                contactDetectionWarning = "No contacts found. Searched \(account.email)'s "
                    + "sent mail (\(sentContacts.count) correspondents) and Gmail's own "
                    + "personal-mail labels, and both came back empty. Pin senders by hand "
                    + "from the Senders view until this is resolved."
            }
        } catch {
            // Fall back to whatever was persisted previously rather than an empty set.
            //
            // Reported through a SEPARATE channel, not scanProgress.status: marking the
            // scan itself failed here would claim the mail fetch broke when it in fact
            // succeeded, and the distinction matters because the consequence is narrow —
            // the protected tier is weaker than it should be, not that nothing scanned.
            let fallback = (try? await contactDetector.loadPersistedContacts(accountId: accountId)) ?? []
            knownContactCount = fallback.count
            contactDetectionWarning = "Contact detection failed (\(error.localizedDescription)). "
                + "Using \(fallback.count) previously-saved contacts — review the plan carefully, "
                + "because fewer contacts means less mail is protected."
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
            if settings == nil { await loadSettings(accountId: accountId) }

            let results = try await categorizeWithFallback(
                emails: uncategorized,
                accountId: accountId,
                contacts: contacts
            )
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
        isRecategorizing = true
        maintenanceStatus = "Re-categorizing…"
        defer { isRecategorizing = false }

        do {
            let contacts = try await contactDetector.loadPersistedContacts(accountId: accountId)
            knownContactCount = contacts.count
            if settings == nil { await loadSettings(accountId: accountId) }

            let all = try await database.fetchEmails(accountId: accountId, limit: 50000, offset: 0)
            guard !all.isEmpty else {
                maintenanceStatus = "Nothing to re-categorize for this account."
                return
            }

            let usingAI = settings?.aiConfig.isEnabled == true
            maintenanceStatus = usingAI
                ? "Re-categorizing \(all.count) emails (cloud enabled)…"
                : "Re-categorizing \(all.count) emails…"

            let results = try await categorizeWithFallback(
                emails: all,
                accountId: accountId,
                contacts: contacts
            )
            try await database.updateCategories(results, accountId: accountId)
            accountStats = try await database.accountStats(accountId: accountId)

            // Report what actually changed. A maintenance action that runs silently is
            // indistinguishable from a button that does nothing.
            let aiInfluenced = results.filter { $0.reason.contains("AI") }.count
            var summary = "Re-categorized \(results.count) emails "
                + "using \(contacts.count) contacts."
            if usingAI {
                let verdicts = (try? await database.cachedVerdictCount(
                    accountId: accountId,
                    modelId: settings?.aiConfig.modelId.isEmpty == false
                        ? settings!.aiConfig.modelId
                        : BedrockLLMTransport.defaultModelId,
                    promptVersion: SenderClassificationPrompt.version
                )) ?? 0
                summary += " Cloud verdicts cached: \(verdicts). "
                    + "Decisions citing the model: \(aiInfluenced)."
            }
            maintenanceStatus = summary
        } catch {
            maintenanceStatus = "Re-categorization failed: \(error.localizedDescription)"
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
            // Use the user's saved rules rather than the hardcoded defaults —
            // ActionRules was Codable from the start but never persisted or edited.
            if settings == nil { await loadSettings(accountId: accountId) }
            let planner = ActionPlanner(rules: settings?.actionRules ?? .default)
            actionPlan = planner.generatePlan(emails: emails, accountId: accountId)
        } catch {
            print("Plan generation failed: \(error)")
        }
    }

    /// Re-run OAuth for an account that already exists, WITHOUT touching its data.
    ///
    /// Necessary because Google expires refresh tokens after 7 days while the OAuth
    /// consent screen is in testing mode, so an account stops working periodically and
    /// needs fresh consent.
    ///
    /// The obvious workaround — remove the account and add it again — is destructive and
    /// does not even work: `deleteAccount` cascades to `emailMetadata` and would discard
    /// every scanned message, and re-adding then fails on the UNIQUE constraint on
    /// `email`. This path keeps the row and its mail and only replaces the credentials.
    @MainActor
    func reconnectAccount(_ account: EmailAccount) async {
        isReconnecting = true
        lastExecutionError = nil
        defer { isReconnecting = false }

        do {
            let tokens = try await authService.authenticate()

            // Verify the Google account that just signed in is the one being repaired.
            // Without this, signing in as the wrong account silently stores a token that
            // does not match the row, and the next scan reads someone else's mailbox.
            let rateLimiter = RateLimiter(maxRequestsPerSecond: 45)
            let client = GmailAPIClient(
                tokens: tokens,
                rateLimiter: rateLimiter,
                retryPolicy: RetryPolicy()
            )
            let profile = try await client.getProfile()

            guard profile.emailAddress.lowercased() == account.email.lowercased() else {
                lastExecutionError = "You signed in as \(profile.emailAddress), but this "
                    + "account is \(account.email). Nothing was changed — reconnect again "
                    + "and choose \(account.email)."
                try? authService.signOut()
                return
            }

            configureGmail(with: tokens)
            selectedAccount = account
            // Clear the stale failure so the banner does not outlive the problem.
            scanProgress = nil
        } catch {
            lastExecutionError = "Reconnect failed: \(error.localizedDescription)"
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

    // MARK: - Sender Triage

    func loadSenderSummaries(accountId: Int64) async {
        isLoadingSenders = true
        defer { isLoadingSenders = false }
        do {
            senderSummaries = try await database.senderSummaries(accountId: accountId)
            senderRules = try await database.fetchSenderRules(accountId: accountId)
        } catch {
            print("Failed to load sender summaries: \(error)")
        }
    }

    /// Apply a decision to every message from a sender, optionally persisting it as a
    /// standing rule so future mail is handled without asking again.
    ///
    /// Marks rather than executes: nothing reaches the provider until the user presses
    /// Execute, so a mis-click on a 400-message sender is recoverable by clearing it.
    func decideSender(
        _ summary: SenderSummary,
        action: EmailAction,
        accountId: Int64,
        persistAsRule: Bool,
        ruleScope: RuleScope = .address,
        keepNewest: Int = 0
    ) async {
        guard !summary.isProtected else {
            lastExecutionError = "\(summary.senderEmail) is a known contact — protected mail is never bulk-actioned."
            return
        }

        do {
            let ids: [String]
            if keepNewest > 0 {
                ids = try await database.messageIds(
                    accountId: accountId,
                    senderEmail: summary.senderEmail,
                    keepNewest: keepNewest
                )
            } else {
                ids = try await database.messageIds(
                    accountId: accountId,
                    senderEmail: summary.senderEmail
                )
            }

            try await database.markEmailsActioned(
                messageIds: ids,
                accountId: accountId,
                action: action
            )

            if persistAsRule {
                let pattern = ruleScope == .domain
                    ? EmailHeaderParser.extractDomain(summary.senderEmail)
                    : summary.senderEmail
                try await database.saveSenderRule(
                    SenderRule(
                        accountId: accountId,
                        pattern: pattern,
                        scope: ruleScope,
                        action: action
                    )
                )
            }

            await loadSenderSummaries(accountId: accountId)
            accountStats = try await database.accountStats(accountId: accountId)
        } catch {
            lastExecutionError = "Failed to apply decision: \(error.localizedDescription)"
        }
    }

    /// Pin a sender as a contact so their mail is protected from every rule and plan.
    func protectSender(_ summary: SenderSummary, accountId: Int64) async {
        await pinContact(email: summary.senderEmail, accountId: accountId)
        await loadSenderSummaries(accountId: accountId)
    }

    // MARK: - Standing Rules

    /// Re-apply every enabled sender rule to unmarked mail.
    ///
    /// Runs after each scan so standing decisions cover new arrivals automatically.
    /// Protected mail is excluded at the query level, so a rule can never touch a
    /// contact's messages even if a rule pattern would otherwise match.
    @discardableResult
    func applySenderRules(accountId: Int64) async -> Int {
        do {
            let rules = try await database.fetchEnabledSenderRules(accountId: accountId)
            guard !rules.isEmpty else {
                lastRuleMatchCount = 0
                return 0
            }

            let candidates = try await database.fetchUnmarkedActionableEmails(accountId: accountId)
            var byAction: [EmailAction: [String]] = [:]
            for email in candidates {
                // First matching rule wins; rules are ordered newest-first.
                if let rule = rules.first(where: { $0.matches(email) }) {
                    byAction[rule.action, default: []].append(email.messageId)
                }
            }

            for (action, ids) in byAction {
                try await database.markEmailsActioned(
                    messageIds: ids,
                    accountId: accountId,
                    action: action
                )
            }

            let total = byAction.values.reduce(0) { $0 + $1.count }
            lastRuleMatchCount = total
            return total
        } catch {
            print("Failed to apply sender rules: \(error)")
            return 0
        }
    }

    func loadSenderRules(accountId: Int64) async {
        senderRules = (try? await database.fetchSenderRules(accountId: accountId)) ?? []
    }

    func deleteSenderRule(_ rule: SenderRule, accountId: Int64) async {
        guard let id = rule.id else { return }
        try? await database.deleteSenderRule(id: id)
        await loadSenderRules(accountId: accountId)
    }

    func toggleSenderRule(_ rule: SenderRule, accountId: Int64) async {
        guard let id = rule.id else { return }
        try? await database.setSenderRuleEnabled(id: id, isEnabled: !rule.isEnabled)
        await loadSenderRules(accountId: accountId)
    }

    // MARK: - Settings

    func loadSettings(accountId: Int64) async {
        settings = try? await database.accountSettings(accountId: accountId)
    }

    func updateScanScope(_ scope: ScanScope, accountId: Int64) async {
        var updated = settings ?? AccountSettings(accountId: accountId)
        updated.scanScope = scope
        settings = updated
        try? await database.saveAccountSettings(updated)
    }

    func updateActionRules(_ rules: ActionRules, accountId: Int64) async {
        var updated = settings ?? AccountSettings(accountId: accountId)
        updated.actionRules = rules
        settings = updated
        try? await database.saveAccountSettings(updated)
    }

    // MARK: - Unsubscribe

    /// Attempt to unsubscribe from a sender.
    ///
    /// Only ever user-initiated. One-click is attempted only when the sender advertised
    /// RFC 8058 support; otherwise the web page is opened for the user to complete,
    /// because a blind POST to a GET-only confirmation page can do the wrong thing.
    func unsubscribe(from summary: SenderSummary, accountId: Int64) async {
        unsubscribeMessage = nil

        do {
            guard let info = try await database.latestUnsubscribeInfo(
                accountId: accountId,
                senderEmail: summary.senderEmail
            ) else {
                unsubscribeMessage = "No unsubscribe option found for \(summary.senderEmail)."
                return
            }

            let outcome = try await unsubscribeService.unsubscribe(
                header: info.header,
                supportsOneClick: info.supportsOneClick
            )

            switch outcome {
            case .oneClickSucceeded:
                try await database.recordUnsubscribeAttempt(
                    UnsubscribeAttempt(
                        senderEmail: summary.senderEmail,
                        method: "one-click",
                        succeeded: true
                    ),
                    accountId: accountId
                )
                unsubscribeMessage = "Unsubscribed from \(summary.senderEmail). "
                    + "If mail keeps arriving after 10 days it will be flagged as ignored."

            case .needsBrowser(let url):
                NSWorkspace.shared.open(url)
                try await database.recordUnsubscribeAttempt(
                    UnsubscribeAttempt(
                        senderEmail: summary.senderEmail,
                        method: "browser",
                        succeeded: false,
                        note: "Opened \(url.host ?? "the sender's page") — needs completing in the browser."
                    ),
                    accountId: accountId
                )
                unsubscribeMessage = "This sender needs a web page — opened in your browser."

            case .needsEmail(let address):
                unsubscribeMessage = "This sender only accepts unsubscribe by email. "
                    + "Send an empty message to \(address) from \(selectedAccount?.email ?? "this account")."

            case .unavailable:
                unsubscribeMessage = "The unsubscribe header from \(summary.senderEmail) has no usable link."
            }
        } catch {
            unsubscribeMessage = "Unsubscribe failed: \(error.localizedDescription)"
        }
    }

    func loadIgnoredUnsubscribes(accountId: Int64) async {
        sendersIgnoringUnsubscribe = (try? await database.sendersIgnoringUnsubscribe(accountId: accountId)) ?? []
    }

    // MARK: - Review queue

    @Published var reviewQueue: [EmailMetadata] = []
    @Published var isLoadingReviewQueue = false
    /// Which account the current `reviewQueue` was loaded FOR.
    ///
    /// An id rather than a bool, because a bool would let one account's completed load vouch
    /// for another's: switch accounts and the screen would present the previous account's
    /// result as this one's finished answer. The id makes "loaded" a claim about a specific
    /// account, which is the only form of it that is true.
    ///
    /// It exists at all because an empty `reviewQueue` is otherwise ambiguous — "nothing to
    /// review" and "nothing fetched yet" look identical — and the screen resolved that by
    /// asserting the first, displaying "Nothing awaiting review" while 103 emails were still
    /// on their way.
    @Published var loadedReviewQueueAccountId: Int64?
    @Published var reviewStatus: String?

    func loadReviewQueue(accountId: Int64) async {
        isLoadingReviewQueue = true
        defer {
            isLoadingReviewQueue = false
            loadedReviewQueueAccountId = accountId
        }
        do {
            reviewQueue = try await database.emailsAwaitingReview(accountId: accountId)
        } catch {
            reviewQueue = []
            reviewStatus = "Could not load the review queue: \(error.localizedDescription)"
        }
    }

    /// Record a per-message decision and reflect it immediately.
    ///
    /// Re-categorizes only the affected mail rather than the mailbox, so a bulk accept of 54
    /// emails takes effect at once. The decision outranks every classifier, so this is really
    /// just writing the new tier through.
    func recordDisposal(
        _ decision: DisposalDecision,
        messageIds: [String],
        accountId: Int64
    ) async {
        guard !messageIds.isEmpty else { return }
        do {
            try await database.recordDisposalDecision(
                decision, messageIds: messageIds, accountId: accountId
            )
            let affected = try await recategorizeMessages(
                accountId: accountId, messageIds: messageIds
            )
            reviewStatus = decision == .dispose
                ? "Marked \(affected) email\(affected == 1 ? "" : "s") as safe to delete."
                : "Keeping \(affected) email\(affected == 1 ? "" : "s")."
            await loadReviewQueue(accountId: accountId)
        } catch {
            reviewStatus = "Could not save that: \(error.localizedDescription)"
        }
    }

    /// Re-run the engine over specific messages only.
    @discardableResult
    private func recategorizeMessages(
        accountId: Int64,
        messageIds: [String]
    ) async throws -> Int {
        let emails = try await database.emails(accountId: accountId, messageIds: messageIds)
        guard !emails.isEmpty else { return 0 }
        let contacts = try await database.knownContactEmails(accountId: accountId)
        let engine = makeEngine(accountId: accountId, contacts: contacts)
        let results = try await engine.categorize(emails: emails)
        try await database.updateCategories(results, accountId: accountId)
        return results.count
    }

    // MARK: - Active learning

    @Published var triageCandidates: [TriageCandidate] = []
    @Published var isLoadingCandidates = false
    /// Which account the candidate list was loaded for. Same reasoning as the review queue: an
    /// empty list before a load has finished is not an empty list, and "Nothing left to decide"
    /// is a claim this screen must not make until it has actually looked.
    @Published var loadedCandidatesAccountId: Int64?
    @Published var agreement: (confirmed: Int, overturned: Int) = (0, 0)

    /// Load the senders worth asking about, highest leverage first.
    func loadTriageCandidates(accountId: Int64) async {
        isLoadingCandidates = true
        defer {
            isLoadingCandidates = false
            loadedCandidatesAccountId = accountId
        }

        // Keyed to the CURRENT model and prompt, so the queue shows the verdict the user
        // would actually be endorsing rather than one from a superseded configuration.
        let transport = currentTransportIdentity()
        do {
            triageCandidates = try await database.triageCandidates(
                accountId: accountId,
                modelId: transport.modelId,
                promptVersion: transport.promptVersion
            )
            agreement = try await database.agreementRate(accountId: accountId)
        } catch {
            triageCandidates = []
            correctionStatus = "Could not load the decision queue: \(error.localizedDescription)"
        }
    }

    /// Which model's verdicts to show, without constructing a transport that would talk to AWS.
    private func currentTransportIdentity() -> (modelId: String, promptVersion: String) {
        let configured = settings?.aiConfig.modelId ?? ""
        return (
            configured.isEmpty ? BedrockLLMTransport.defaultModelId : configured,
            SenderClassificationPrompt.version
        )
    }

    /// The user endorses what the app says about this sender.
    ///
    /// Records ground truth and changes nothing else. That is deliberate: a confirmation is
    /// the only label this app can collect that is able to measure the pipeline, because a
    /// correction forces the outcome it is then scored against.
    func confirmCandidate(_ candidate: TriageCandidate, accountId: Int64) async {
        guard let category = candidate.currentCategory else { return }
        do {
            try await database.confirmVerdict(
                accountId: accountId,
                senderEmail: candidate.senderEmail,
                category: category,
                mustKeep: candidate.currentTier != .safe
            )
            correctionStatus = "Confirmed \(candidate.senderEmail)"
                + " — recorded as ground truth, nothing re-categorized."
            await loadTriageCandidates(accountId: accountId)
        } catch {
            correctionStatus = "Could not record the confirmation: \(error.localizedDescription)"
        }
    }

    /// The user overturns the verdict: writes a correction AND a label.
    func decideCandidate(
        _ candidate: TriageCandidate,
        accountId: Int64,
        category: EmailCategory,
        mustKeep: Bool,
        subjectPattern: String? = nil
    ) async {
        let correction = UserCorrection(
            accountId: accountId,
            senderEmail: candidate.senderEmail,
            subjectPattern: subjectPattern,
            category: category,
            mustKeep: mustKeep,
            previousCategory: candidate.currentCategory,
            previousTier: candidate.currentTier,
            previousReason: candidate.currentReason
        )
        do {
            try await database.saveCorrection(correction)
            try await database.saveGoldenLabel(
                GoldenLabel(
                    accountId: accountId,
                    senderEmail: candidate.senderEmail,
                    subjectPattern: subjectPattern,
                    expectedCategory: category,
                    disposition: mustKeep ? .mustKeep : .disposable,
                    note: LabelProvenance.correction.note
                )
            )
            await loadCorrections(accountId: accountId)
            let affected = try await recategorizeSender(
                accountId: accountId,
                senderEmail: candidate.senderEmail
            )
            correctionStatus = "Set \(candidate.senderEmail) to \(category.displayName)"
                + " — \(affected) message\(affected == 1 ? "" : "s") updated."
            await loadTriageCandidates(accountId: accountId)
        } catch {
            correctionStatus = "Could not save the decision: \(error.localizedDescription)"
        }
    }

    // MARK: - Corrections

    func loadCorrections(accountId: Int64) async {
        do {
            corrections = try await database.corrections(accountId: accountId)
        } catch {
            corrections = []
            correctionStatus = "Could not load corrections: \(error.localizedDescription)"
        }
    }

    /// Record that the app got a categorization wrong, and act on it immediately.
    ///
    /// Re-categorizes only the affected sender rather than the whole mailbox. A correction
    /// has to visibly take effect at once: making the user wait through a full pass to see
    /// their own instruction applied is how a feature like this stops being used.
    func correctCategory(
        for email: EmailMetadata,
        to category: EmailCategory,
        mustKeep: Bool,
        scopeToSubjectPattern pattern: String? = nil
    ) async {
        let accountId = email.accountId

        let correction = UserCorrection(
            accountId: accountId,
            senderEmail: email.senderEmail,
            subjectPattern: pattern,
            category: category,
            mustKeep: mustKeep,
            previousCategory: email.category,
            previousTier: email.safetyTier,
            previousReason: email.categoryReason
        )

        do {
            try await database.saveCorrection(correction)
            await loadCorrections(accountId: accountId)
            let affected = try await recategorizeSender(
                accountId: accountId,
                senderEmail: email.senderEmail
            )

            var scope = email.senderEmail
            if let pattern {
                scope += " (subjects containing \"\(pattern)\")"
            }
            correctionStatus = "Set \(scope) to \(category.displayName)"
                + (mustKeep ? ", protected" : "")
                + " — \(affected) message\(affected == 1 ? "" : "s") updated."
            // Sender rows carry the tier counts a correction changes, so they would
            // otherwise show stale numbers until the next manual refresh.
            await loadSenderSummaries(accountId: accountId)
        } catch {
            correctionStatus = "Could not save the correction: \(error.localizedDescription)"
        }
    }

    /// Apply the current correction set to one sender's existing mail.
    @discardableResult
    private func recategorizeSender(accountId: Int64, senderEmail: String) async throws -> Int {
        let emails = try await database.emails(accountId: accountId, senderEmail: senderEmail)
        guard !emails.isEmpty else { return 0 }

        let contacts = try await database.knownContactEmails(accountId: accountId)
        let engine = makeEngine(accountId: accountId, contacts: contacts)
        let results = try await engine.categorize(emails: emails)
        try await database.updateCategories(results, accountId: accountId)
        return results.count
    }

    /// Turn corrections into golden labels, so accuracy becomes measurable from ordinary
    /// use rather than a separate labelling chore.
    func promoteCorrectionsToLabels(accountId: Int64) async {
        do {
            let written = try await database.promoteCorrectionsToGoldenLabels(accountId: accountId)
            await loadGoldenLabels(accountId: accountId)
            correctionStatus = written == 0
                ? "No corrections to add yet."
                : "Added \(written) correction\(written == 1 ? "" : "s") to the evaluation set."
        } catch {
            correctionStatus = "Could not update the evaluation set: \(error.localizedDescription)"
        }
    }

    func removeCorrection(_ correction: UserCorrection) async {        guard let id = correction.id else { return }
        do {
            try await database.deleteCorrection(id: id)
            await loadCorrections(accountId: correction.accountId)
            let affected = try await recategorizeSender(
                accountId: correction.accountId,
                senderEmail: correction.senderEmail
            )
            correctionStatus = "Removed the correction for \(correction.senderEmail)"
                + " — \(affected) message\(affected == 1 ? "" : "s") re-evaluated."
        } catch {
            correctionStatus = "Could not remove the correction: \(error.localizedDescription)"
        }
    }

    // MARK: - Golden Set & Evaluation

    func loadGoldenLabels(accountId: Int64) async {
        goldenLabels = (try? await database.fetchGoldenLabels(accountId: accountId)) ?? []
    }

    /// Record a human judgement about a sender for the evaluation set.
    func labelSender(
        _ senderEmail: String,
        expectedCategory: EmailCategory,
        disposition: Disposition,
        note: String? = nil,
        accountId: Int64
    ) async {
        do {
            try await database.saveGoldenLabel(
                GoldenLabel(
                    accountId: accountId,
                    senderEmail: senderEmail,
                    expectedCategory: expectedCategory,
                    disposition: disposition,
                    note: note
                )
            )
            await loadGoldenLabels(accountId: accountId)
        } catch {
            lastExecutionError = "Failed to save label: \(error.localizedDescription)"
        }
    }

    func removeGoldenLabel(senderEmail: String, accountId: Int64) async {
        try? await database.deleteGoldenLabel(accountId: accountId, senderEmail: senderEmail)
        await loadGoldenLabels(accountId: accountId)
    }

    /// Measure the current engine against the labelled set.
    ///
    /// Re-runs categorization with the live contact list and rules, so a rule change is
    /// reflected immediately rather than after a full re-categorization.
    func runEvaluation(accountId: Int64) async {
        isEvaluating = true
        defer { isEvaluating = false }

        do {
            if settings == nil { await loadSettings(accountId: accountId) }
            let contacts = try await contactDetector.loadPersistedContacts(accountId: accountId)
            let engine = RuleBasedEngine(knownContacts: contacts)

            evaluationReport = try await database.evaluate(
                accountId: accountId,
                engine: engine,
                rules: settings?.actionRules ?? .default
            )
        } catch {
            lastExecutionError = "Evaluation failed: \(error.localizedDescription)"
        }
    }

    /// Write the golden set to a JSON file so it can be committed as a test fixture.
    @discardableResult
    func exportGoldenSet(accountId: Int64) async -> URL? {
        guard let account = selectedAccount else { return nil }
        do {
            let export = try await database.exportGoldenSet(
                accountId: accountId,
                accountEmail: account.email
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(export)

            let url = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("triage-golden-set.json")
            try data.write(to: url)
            exportedGoldenSetPath = url.path
            return url
        } catch {
            lastExecutionError = "Export failed: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Engine Selection

    /// The categorization engine for this account.
    ///
    /// Returns the rules-only engine unless cloud categorization is explicitly enabled.
    private func makeEngine(accountId: Int64, contacts: Set<String>) -> CategorizationEngine {
        let rules = RuleBasedEngine(knownContacts: contacts)
        let db = database

        // Corrections wrap whatever sits beneath, so they outrank both the rules and the
        // model, and apply even when the model is switched off.
        func correcting(_ base: CategorizationEngine) -> CategorizationEngine {
            guard !corrections.isEmpty else { return base }
            return CorrectingEngine(base: base, corrections: corrections)
        }

        guard let ai = settings?.aiConfig, ai.isEnabled else { return correcting(rules) }

        let transport = BedrockLLMTransport(
            modelId: ai.modelId.isEmpty ? BedrockLLMTransport.defaultModelId : ai.modelId,
            region: ai.region.isEmpty ? nil : ai.region
        )

        let engine = AICategorizationEngine(
            rules: rules,
            transport: transport,
            cache: db,
            accountId: accountId,
            sampleSubjects: { sender in
                (try? await db.sampleSubjects(accountId: accountId, senderEmail: sender)) ?? []
            },
            // Absent unless explicitly enabled, so there is no path that reads message
            // content without the user having asked for it.
            sampleSnippets: ai.sendBodyPreviews
                ? { sender in
                    (try? await db.sampleSnippets(accountId: accountId, senderEmail: sender)) ?? []
                }
                : nil,
            correctionExamples: {
                (try? await db.correctionExamples(accountId: accountId)) ?? []
            },
            onDiagnostics: { [weak self] diagnostics in
                Task { @MainActor in
                    self?.aiDiagnostics = diagnostics.summary
                }
            }
        )
        return correcting(engine)
    }

    /// Categorize with the configured engine, falling back to rules on failure.
    ///
    /// The fallback ANNOUNCES itself. A silent degradation to local-only would leave the
    /// user believing they had cloud classification when an expired SSO session meant
    /// they did not — and the two produce measurably different tiers.
    private func categorizeWithFallback(
        emails: [EmailMetadata],
        accountId: Int64,
        contacts: Set<String>
    ) async throws -> [CategorizationResult] {
        let engine = makeEngine(accountId: accountId, contacts: contacts)

        if engine is RuleBasedEngine {
            return try await engine.categorize(emails: emails)
        }

        do {
            let results = try await engine.categorize(emails: emails)
            aiStatusMessage = nil
            return results
        } catch {
            aiStatusMessage = "Cloud categorization unavailable — used local rules only. "
                + (error.localizedDescription)
            return try await RuleBasedEngine(knownContacts: contacts).categorize(emails: emails)
        }
    }

    func updateAIConfig(_ config: AIConfig, accountId: Int64) async {
        var updated = settings ?? AccountSettings(accountId: accountId)
        updated.aiConfig = config
        settings = updated
        try? await database.saveAccountSettings(updated)
    }

    /// Verify credentials and model access with one real call.
    ///
    /// Listing models is not proof: a model can appear in the catalogue and still reject
    /// forced tool use, which is what this pipeline depends on.
    func testAIConnection(accountId: Int64) async {
        isTestingAI = true
        aiStatusMessage = nil
        defer { isTestingAI = false }

        guard let ai = settings?.aiConfig else {
            aiStatusMessage = "No settings loaded."
            return
        }

        let transport = BedrockLLMTransport(
            modelId: ai.modelId.isEmpty ? BedrockLLMTransport.defaultModelId : ai.modelId,
            region: ai.region.isEmpty ? nil : ai.region
        )

        let probe = SenderClassificationRequest(
            senderEmail: "deals@example-retailer.com",
            displayName: "Example Retailer",
            sampleSubjects: ["50% off this weekend only", "Your order has shipped"],
            totalEmails: 12,
            hasUnsubscribe: true,
            averageIntervalDays: 3
        )

        do {
            let verdicts = try await transport.classify(senders: [probe])
            if let verdict = verdicts.first {
                aiStatusMessage = "Connected. \(transport.modelId) classified the test sender as "
                    + "\(verdict.category.displayName) "
                    + "(\(Int(verdict.confidence * 100))% confident, mustKeep: \(verdict.mustKeep))."
            } else {
                aiStatusMessage = "The model answered but returned no verdict — "
                    + "it may not support forced tool use."
            }
        } catch {
            aiStatusMessage = "Failed: \(error.localizedDescription)"
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
