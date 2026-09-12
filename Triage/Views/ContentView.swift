import SwiftUI
import Combine
import TriageCore

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            if appState.isScanning, let progress = appState.scanProgress {
                ScanProgressView(progress: progress)
            } else if appState.accounts.isEmpty {
                WelcomeView()
            } else {
                VStack(spacing: 0) {
                    // A failed scan must stay on screen. `isScanning` goes false the
                    // moment the scan throws, and ScanProgressView — the only thing that
                    // rendered the failure — stopped being shown with it, so the error
                    // was computed and then silently discarded. A scan that fails
                    // invisibly is indistinguishable from a scan that does nothing.
                    if let progress = appState.scanProgress,
                       case .failed(let message) = progress.status {
                        ScanFailureBanner(
                            message: message,
                            isReconnecting: appState.isReconnecting,
                            onReconnect: appState.selectedAccount.map { account in
                                { Task { await appState.reconnectAccount(account) } }
                            },
                            onDismiss: { appState.scanProgress = nil }
                        )
                    }

                    // Contact detection failing is narrower than a scan failing, but it
                    // was being written to a property nothing rendered — the same
                    // invisible-error mistake as the scan banner. Shown separately and
                    // less alarmingly, because the consequence is specific: fewer
                    // contacts means less mail is protected.
                    if let warning = appState.contactDetectionWarning {
                        ContactWarningBanner(message: warning) {
                            appState.contactDetectionWarning = nil
                        }
                    }

                    switch appState.detailRoute {
                    case .overview:
                        InboxOverviewView()
                    case .decide:
                        DecisionQueueView()
                    case .review:
                        ReviewInboxView()
                    case .senders:
                        SenderTriageView()
                    case .history:
                        HistoryView()
                    case .evaluation:
                        EvaluationView()
                    case .settings:
                        SettingsView()
                    }
                }
            }
        }
        .task {
            await appState.loadAccounts()
        }
        // The primary action belongs in the toolbar, not buried in one view.
        // Scan/Rescan previously existed ONLY inside InboxOverviewView and only when
        // selectedAccount was non-nil, so switching to Senders, History, Accuracy or
        // Settings — or losing the sidebar selection — made scanning unreachable.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await appState.scanSelectedAccount() }
                } label: {
                    if appState.isScanning {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small)
                            Text("Scanning…")
                        }
                    } else {
                        Label(
                            appState.accountStats == nil ? "Scan" : "Rescan",
                            systemImage: "arrow.clockwise"
                        )
                    }
                }
                .disabled(appState.isScanning || appState.scanTarget == nil)
                .help(appState.scanTarget.map { "Scan \($0.email)" } ?? "Add an account first")
            }
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @State private var accountToDelete: EmailAccount?
    @State private var showDeleteConfirmation = false

    var body: some View {
        List(selection: $appState.selectedAccount) {
            Section("Accounts") {
                ForEach(appState.accounts) { account in
                    Label(account.email, systemImage: account.provider.iconName)
                        .tag(account)
                        .contextMenu {
                            Button {
                                Task {
                                    appState.selectedAccount = account
                                    await appState.startGmailScan(for: account)
                                }
                            } label: {
                                Label("Scan This Account", systemImage: "arrow.clockwise")
                            }
                            .disabled(appState.isScanning)

                            Button {
                                Task { await appState.reconnectAccount(account) }
                            } label: {
                                Label("Reconnect…", systemImage: "arrow.triangle.2.circlepath")
                            }

                            Divider()

                            Button(role: .destructive) {
                                accountToDelete = account
                                showDeleteConfirmation = true
                            } label: {
                                Label("Remove Account", systemImage: "trash")
                            }
                        }
                }
            }

            Section("Views") {
                SidebarRouteRow(
                    title: "Inbox Overview",
                    systemImage: "tray.2",
                    route: .overview
                )
                // Placed second, directly after the overview: this is the screen that turns a
                // long review queue into a few decisions, so it should be found before the
                // per-sender and per-category lists a user would otherwise start scrolling.
                SidebarRouteRow(
                    title: "Decide",
                    systemImage: "checklist",
                    route: .decide
                )
                SidebarRouteRow(
                    title: "Review",
                    systemImage: "tray.full",
                    route: .review
                )
                SidebarRouteRow(
                    title: "Senders",
                    systemImage: "person.2.badge.gearshape",
                    route: .senders
                )
                SidebarRouteRow(
                    title: "History",
                    systemImage: "clock.arrow.circlepath",
                    route: .history
                )
                SidebarRouteRow(
                    title: "Accuracy",
                    systemImage: "chart.bar.doc.horizontal",
                    route: .evaluation
                )
                SidebarRouteRow(
                    title: "Settings",
                    systemImage: "gearshape",
                    route: .settings
                )
            }

            Section {
                NavigationLink {
                    AddAccountView()
                } label: {
                    Label("Add Account", systemImage: "plus.circle")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Triage")
        .alert("Remove Account", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                if let account = accountToDelete {
                    Task { await appState.deleteAccount(account) }
                }
            }
        } message: {
            // Spell out the actual consequence: emailMetadata cascades on the account
            // row, so this discards every scanned message and a rescan has to refetch
            // them all. Anyone here because of an expired token wants Reconnect instead.
            Text("This deletes the account AND every email already scanned for it — a rescan would have to fetch them all again. Your mail on Gmail is not affected.\n\nIf you are only fixing an expired login, use “Reconnect…” instead: it keeps the scanned mail.")
        }
    }
}

/// Persistent, dismissible banner for a failed scan.
///
/// Text is selectable on purpose: the useful part of a Gmail failure is usually the
/// provider's own message, and it needs to be copyable to be actionable.
struct ScanFailureBanner: View {
    let message: String
    let isReconnecting: Bool
    let onReconnect: (() -> Void)?
    let onDismiss: () -> Void

    /// Whether this failure is a credential problem, which is the one case the user can
    /// fix from here rather than by reading the message.
    private var looksLikeAuthFailure: Bool {
        ["invalid_grant", "token", "auth", "credential", "401", "unauthor"]
            .contains { message.localizedCaseInsensitiveContains($0) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Scan failed")
                    .fontWeight(.semibold)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                // The overwhelmingly common cause, stated where it is useful rather
                // than left for the user to work out: Google expires refresh tokens
                // after 7 days while the OAuth consent screen is in testing mode.
                if looksLikeAuthFailure {
                    Text("Google expires refresh tokens after 7 days while the OAuth consent screen is in testing mode, so an account connected more than a week ago stops working. Reconnect keeps every email already scanned — unlike removing the account, which deletes them.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }

            Spacer()

            VStack(spacing: 6) {
                if looksLikeAuthFailure, let onReconnect {
                    Button(action: onReconnect) {
                        if isReconnecting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Reconnect…")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isReconnecting)
                }

                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }
}

/// Contact detection problems, which weaken the protected tier without breaking a scan.
struct ContactWarningBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.yellow)

            VStack(alignment: .leading, spacing: 2) {
                Text("Contacts not detected")
                    .fontWeight(.semibold)
                    .font(.callout)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Nothing is in the Protected tier until contacts exist, so do not execute a delete plan yet.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Spacer()

            Button("Dismiss", action: onDismiss)
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(10)
        .background(Color.yellow.opacity(0.12))
    }
}

/// A sidebar entry that switches the detail column.
///
/// Not a `NavigationLink` because the detail route is a separate axis from the
/// sidebar's account selection — a link would push into the sidebar column instead.
struct SidebarRouteRow: View {
    @EnvironmentObject private var appState: AppState

    let title: String
    let systemImage: String
    let route: AppState.DetailRoute

    var body: some View {
        Button {
            appState.detailRoute = route
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(appState.detailRoute == route ? Color.accentColor : Color.primary)
        .fontWeight(appState.detailRoute == route ? .semibold : .regular)
    }
}

struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Welcome to Triage")
                .font(.largeTitle)
                .fontWeight(.semibold)
            Text("Add your Gmail or Yahoo account to get started.")
                .font(.title3)
                .foregroundStyle(.secondary)
            NavigationLink("Add Account", destination: AddAccountView())
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ScanProgressView: View {
    let progress: ScanProgress

    var body: some View {
        VStack(spacing: 20) {
            ProgressView(value: progressValue) {
                Text(progress.status.description)
                    .font(.headline)
            } currentValueLabel: {
                Text("\(progress.fetched) / \(progress.total) emails")
            }
            .progressViewStyle(.linear)
            .frame(maxWidth: 400)

            if case .failed(let message) = progress.status {
                Text(message)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var progressValue: Double {
        guard progress.total > 0 else { return 0 }
        return Double(progress.fetched) / Double(progress.total)
    }
}

struct InboxOverviewView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            if let stats = appState.accountStats {
                // Show results after scan
                VStack(spacing: 20) {
                    Text("Inbox Overview")
                        .font(.largeTitle)

                    HStack(spacing: 40) {
                        StatCard(title: "Total Emails", value: "\(stats.totalEmails)")
                        StatCard(title: "Unread", value: "\(stats.unreadEmails)")
                        StatCard(title: "Categorized", value: "\(stats.categorizedEmails)")
                    }

                    if !stats.categoryBreakdown.isEmpty {
                        CategoryBreakdownView(stats: stats)
                    }

                    HStack(spacing: 12) {
                        Button("Rescan") {
                            Task { await appState.scanSelectedAccount() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(appState.isScanning || appState.scanTarget == nil)

                        Button("Generate Action Plan") {
                            Task {
                                await appState.generatePlan()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }

                    if let plan = appState.actionPlan {
                        ActionPlanView(plan: plan)
                    }

                    // Pending manual actions
                    PendingActionsView()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // No scan done yet
                Text("Inbox Overview")
                    .font(.largeTitle)
                Text("Select an account and scan to begin cleanup.")
                    .foregroundStyle(.secondary)

                if let account = appState.scanTarget {
                    Button("Scan \(account.email)") {
                        Task { await appState.scanSelectedAccount() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(appState.isScanning)
                } else {
                    Text("Add an account to get started.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title)
                .fontWeight(.bold)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

// MARK: - Pending Actions View

struct PendingActionsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var markedEmails: [EmailMetadata] = []
    @State private var isLoading = false
    @State private var isExecuting = false
    @State private var executionDone = false
    @State private var errorMessage: String?
    @State private var refreshId = UUID()

    var body: some View {
        Group {
            if !markedEmails.isEmpty || executionDone {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()

                    HStack {
                        Image(systemName: "tray.full")
                        Text("Pending Actions")
                            .font(.headline)
                        Spacer()
                        Text("\(markedForDeletion.count) to delete, \(markedForArchive.count) to archive")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button {
                            Task { await loadMarked() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                    }

                    // Preview list
                    if !markedEmails.isEmpty {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(markedEmails, id: \.messageId) { email in
                                    HStack {
                                        Image(systemName: email.actionTaken == .deleted ? "trash" : "archivebox")
                                            .foregroundStyle(email.actionTaken == .deleted ? .red : .blue)
                                            .font(.caption)
                                        Text(email.subject)
                                            .lineLimit(1)
                                            .font(.caption)
                                        Spacer()
                                        Text(email.senderEmail)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 150)
                    }

                    if let error = errorMessage {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }

                    if executionDone {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Actions executed successfully on Gmail!")
                        }
                        .font(.callout)
                    } else {
                        HStack {
                            Button("Clear All") {
                                Task { await clearMarked() }
                            }
                            .buttonStyle(.bordered)

                            Spacer()

                            Button {
                                Task { await executeActions() }
                            } label: {
                                if isExecuting {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Executing...")
                                } else {
                                    Label("Execute on Gmail", systemImage: "paperplane.fill")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isExecuting)
                        }
                    }
                }
                .padding()
                .padding(.horizontal)
            }
        }
        .task(id: refreshId) {
            await loadMarked()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            Task { await loadMarked() }
        }
    }

    private var markedForDeletion: [EmailMetadata] {
        markedEmails.filter { $0.actionTaken == .deleted }
    }

    private var markedForArchive: [EmailMetadata] {
        markedEmails.filter { $0.actionTaken == .archived }
    }

    private func loadMarked() async {
        guard let account = appState.selectedAccount, let accountId = account.id else { return }
        do {
            markedEmails = try await appState.fetchMarkedEmails(accountId: accountId)
        } catch {
            print("Failed to load marked emails: \(error)")
        }
    }

    private func executeActions() async {
        isExecuting = true
        errorMessage = nil
        defer { isExecuting = false }
        do {
            try await appState.executePendingActions(emails: markedEmails)
            executionDone = true
            markedEmails = []
            // Refresh stats
            if let account = appState.selectedAccount, let accountId = account.id {
                appState.accountStats = try? await appState.refreshStats(accountId: accountId)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearMarked() async {
        guard let account = appState.selectedAccount, let accountId = account.id else { return }
        let messageIds = markedEmails.map(\.messageId)
        do {
            try await appState.clearMarkedEmails(messageIds: messageIds, accountId: accountId)
            markedEmails = []
        } catch {
            print("Failed to clear: \(error)")
        }
    }
}

struct AddAccountView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isAuthenticating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Add Account")
                .font(.title)

            if isAuthenticating {
                ProgressView("Authenticating...")
            }

            if let error = errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            Button {
                Task {
                    await connectGmail()
                }
            } label: {
                Label("Connect Gmail", systemImage: "envelope")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isAuthenticating)

            Button {
                // Will trigger Yahoo IMAP setup
            } label: {
                Label("Connect Yahoo", systemImage: "envelope.badge")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isAuthenticating)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func connectGmail() async {
        isAuthenticating = true
        errorMessage = nil
        defer { isAuthenticating = false }

        do {
            // Uses AppState's shared auth service, so the token it stores is already in
            // that instance's cache and the following scan needs no further prompt.
            let tokens = try await appState.authService.authenticate()
            appState.configureGmail(with: tokens)

            // Save the account to the database
            await appState.addGmailAccount(tokens: tokens)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
