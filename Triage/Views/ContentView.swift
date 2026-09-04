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
                switch appState.detailRoute {
                case .overview:
                    InboxOverviewView()
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
        .task {
            await appState.loadAccounts()
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
            Text("This will remove the account and all its local data. Your emails on Gmail won't be affected.")
        }
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
                        if let account = appState.selectedAccount {
                            Button("Rescan") {
                                Task {
                                    await appState.startGmailScan(for: account)
                                }
                            }
                            .buttonStyle(.bordered)
                        }

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

                if let account = appState.selectedAccount {
                    Button("Scan \(account.email)") {
                        Task {
                            await appState.startGmailScan(for: account)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
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
