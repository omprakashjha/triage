import SwiftUI
import TriageCore

/// Shows the category breakdown after scanning and categorization
struct CategoryBreakdownView: View {
    @EnvironmentObject private var appState: AppState
    let stats: AccountStats

    @State private var selectedCategory: EmailCategory?
    @State private var selectedTier: SafetyTier?

    var body: some View {
        HSplitView {
            // Left: Category list
            categoryList
                .frame(minWidth: 250, maxWidth: 350)

            // Right: Email list for selected category or tier
            if let category = selectedCategory {
                EmailListView(category: category)
                    .onChange(of: selectedCategory) { _, _ in selectedTier = nil }
            } else if let tier = selectedTier {
                TierEmailListView(tier: tier)
            } else {
                VStack {
                    Image(systemName: "envelope.open")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Select a category to view emails")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Category List

    private var categoryList: some View {
        VStack(spacing: 0) {
            // Summary bar
            VStack(alignment: .leading, spacing: 8) {
                Text("Inbox Analysis")
                    .font(.headline)

                HStack(spacing: 16) {
                    Label("\(stats.totalEmails) total", systemImage: "envelope")
                    Label("\(stats.safeToAction) safe", systemImage: "checkmark.shield")
                        .foregroundStyle(.green)
                    Label("\(stats.protected_) protected", systemImage: "lock.shield")
                        .foregroundStyle(.blue)
                }
                .font(.caption)

                // Contact detection is what makes the protected tier possible at all.
                // Calling that out explicitly, because a silent zero here means nothing
                // in the mailbox is shielded from the action plan.
                if appState.knownContactCount == 0 {
                    Label(
                        "No contacts detected — nothing is protected. Rescan to build your contact list.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                } else {
                    Label(
                        "\(appState.knownContactCount) known contacts protected",
                        systemImage: "person.crop.circle.badge.checkmark"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            // Categories
            List(selection: $selectedCategory) {
                Section("Categories") {
                    ForEach(sortedCategories, id: \.category) { item in
                        CategoryRow(
                            category: item.category,
                            count: item.count,
                            percentage: Double(item.count) / Double(max(stats.totalEmails, 1))
                        )
                        .tag(item.category)
                    }
                }

                Section("Safety Tiers") {
                    TierRow(tier: .safe, count: stats.tierBreakdown[.safe] ?? 0)
                        .onTapGesture { selectedCategory = nil; selectedTier = .safe }
                    TierRow(tier: .review, count: stats.tierBreakdown[.review] ?? 0)
                        .onTapGesture { selectedCategory = nil; selectedTier = .review }
                    TierRow(tier: .protected_, count: stats.tierBreakdown[.protected_] ?? 0)
                        .onTapGesture { selectedCategory = nil; selectedTier = .protected_ }
                }

                if stats.uncategorizedEmails > 0 {
                    Section {
                        Label("\(stats.uncategorizedEmails) uncategorized", systemImage: "questionmark.circle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            // Action button
            VStack {
                Button {
                    Task { await appState.generatePlan() }
                } label: {
                    Label("Generate Action Plan", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
        }
    }

    private var sortedCategories: [(category: EmailCategory, count: Int)] {
        EmailCategory.allCases.compactMap { cat in
            guard let count = stats.categoryBreakdown[cat], count > 0 else { return nil }
            return (category: cat, count: count)
        }.sorted { $0.count > $1.count }
    }
}

// MARK: - Category Row

struct CategoryRow: View {
    let category: EmailCategory
    let count: Int
    let percentage: Double

    var body: some View {
        HStack {
            Image(systemName: category.iconName)
                .frame(width: 20)
                .foregroundStyle(colorForCategory)

            Text(category.displayName)

            Spacer()

            Text("\(count)")
                .font(.body)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var colorForCategory: Color {
        switch category {
        case .newsletter: return .purple
        case .promotion: return .orange
        case .notification: return .blue
        case .transactional: return .green
        case .social: return .pink
        case .personal: return .teal
        case .unknown: return .gray
        }
    }
}

// MARK: - Tier Row

struct TierRow: View {
    let tier: SafetyTier
    let count: Int

    var body: some View {
        HStack {
            Circle()
                .fill(tierColor)
                .frame(width: 8, height: 8)

            Text(tier.displayName)

            Spacer()

            Text("\(count)")
                .foregroundStyle(.secondary)
        }
    }

    private var tierColor: Color {
        switch tier {
        case .safe: return .green
        case .review: return .orange
        case .protected_: return .blue
        }
    }
}

// MARK: - Confidence Badge

/// Renders the engine's own confidence in a decision.
///
/// Deliberately shown rather than hidden: the confidence values drive the review
/// ordering, and a user who can see "45%" next to a delete recommendation is far
/// better placed to catch a bad call than one shown only the category.
struct ConfidenceBadge: View {
    let confidence: Double

    var body: some View {
        Text("\(Int((confidence * 100).rounded()))% confident")
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(tint.opacity(0.15))
            )
            .foregroundStyle(tint)
    }

    private var tint: Color {
        if confidence >= 0.8 { return .green }
        if confidence >= 0.6 { return .orange }
        return .red
    }
}

// MARK: - Email List View

struct EmailListView: View {
    /// The email whose categorization the user is fixing, if any.
    @State private var correctingEmail: EmailMetadata?

    @EnvironmentObject private var appState: AppState
    let category: EmailCategory

    @State private var emails: [EmailMetadata] = []
    @State private var isLoading = false
    @State private var selectedEmailForSimilar: EmailMetadata?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: category.iconName)
                Text(category.displayName)
                    .font(.headline)
                Text("(\(emails.count) emails)")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()

            Divider()

            // Email table
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if emails.isEmpty {
                Text("No emails in this category")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(emails) {
                    TableColumn("Sender") { email in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(email.sender)
                                .lineLimit(1)
                            Text(email.senderEmail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        // Right-click too: a table row is where a macOS user reaches for a
                        // context menu first.
                        .contextMenu {
                            Button("Correct this categorization…") { correctingEmail = email }
                        }
                    }
                    .width(min: 150, ideal: 200)

                    TableColumn("Subject") { email in
                        Text(email.subject)
                            .lineLimit(1)
                    }
                    .width(min: 200, ideal: 300)

                    TableColumn("") { email in
                        Button {
                            correctingEmail = email
                        } label: {
                            Image(systemName: "pencil.line")
                        }
                        .buttonStyle(.borderless)
                        .help("Correct this categorization")
                    }
                    .width(28)

                    TableColumn("Date") { email in
                        Text(email.date, style: .date)
                            .font(.caption)
                    }
                    .width(80)

                    // The engine already computes a justification and a confidence for
                    // every decision; showing them is what lets a user tell a good
                    // call from a bad one before approving anything.
                    TableColumn("Why") { email in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(email.categoryReason ?? "—")
                                .font(.caption2)
                                .lineLimit(2)
                                .foregroundStyle(.secondary)
                            if let confidence = email.categoryConfidence {
                                ConfidenceBadge(confidence: confidence)
                            }
                        }
                    }
                    .width(min: 140, ideal: 200)

                    TableColumn("Actions") { email in
                        Button("Find Similar") {
                            selectedEmailForSimilar = email
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    .width(90)
                }
            }
        }
        .task(id: category) {
            await loadEmails()
        }
        .sheet(item: $selectedEmailForSimilar) { email in
            SimilarEmailsView(sourceEmail: email)
                .environmentObject(appState)
        }
        .sheet(item: $correctingEmail) { email in
            CorrectionSheet(email: email)
                .environmentObject(appState)
        }
    }

    private func loadEmails() async {
        isLoading = true
        defer { isLoading = false }
        guard let account = appState.selectedAccount, let accountId = account.id else { return }
        do {
            emails = try await appState.fetchEmails(accountId: accountId, category: category)
        } catch {
            print("Failed to load emails: \(error)")
        }
    }
}

// MARK: - Tier Email List View

struct TierEmailListView: View {
    /// The email whose categorization the user is fixing, if any.
    @State private var correctingEmail: EmailMetadata?

    @EnvironmentObject private var appState: AppState
    let tier: SafetyTier

    @State private var emails: [EmailMetadata] = []
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Circle()
                    .fill(tierColor)
                    .frame(width: 10, height: 10)
                Text(tier.displayName)
                    .font(.headline)
                Text("(\(emails.count) emails)")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if emails.isEmpty {
                Text("No emails in this tier")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(emails) {
                    TableColumn("Sender") { email in
                        VStack(alignment: .leading) {
                            Text(email.sender)
                                .fontWeight(.medium)
                            Text(email.senderEmail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contextMenu {
                            Button("Correct this categorization…") { correctingEmail = email }
                        }
                    }
                    .width(min: 150, ideal: 200)

                    TableColumn("Subject") { email in
                        Text(email.subject)
                            .lineLimit(1)
                    }
                    .width(min: 200, ideal: 300)

                    TableColumn("") { email in
                        Button {
                            correctingEmail = email
                        } label: {
                            Image(systemName: "pencil.line")
                        }
                        .buttonStyle(.borderless)
                        .help("Correct this categorization")
                    }
                    .width(28)

                    TableColumn("Category") { email in
                        if let category = email.category {
                            Text(category.displayName)
                                .font(.caption)
                        }
                    }
                    .width(80)

                    TableColumn("Date") { email in
                        Text(email.date, style: .date)
                            .font(.caption)
                    }
                    .width(80)

                    TableColumn("Why") { email in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(email.categoryReason ?? "—")
                                .font(.caption2)
                                .lineLimit(2)
                                .foregroundStyle(.secondary)
                            if let confidence = email.categoryConfidence {
                                ConfidenceBadge(confidence: confidence)
                            }
                        }
                    }
                    .width(min: 140, ideal: 220)
                }
            }
        }
        .task(id: tier) {
            await loadEmails()
        }
        .sheet(item: $correctingEmail) { email in
            CorrectionSheet(email: email)
                .environmentObject(appState)
        }
    }

    private var tierColor: Color {
        switch tier {
        case .safe: return .green
        case .review: return .orange
        case .protected_: return .blue
        }
    }

    private func loadEmails() async {
        isLoading = true
        defer { isLoading = false }
        guard let account = appState.selectedAccount, let accountId = account.id else { return }
        do {
            // The review tier is a work queue, so order it weakest-confidence first.
            // Other tiers are reference lists and stay newest-first.
            if tier == .review {
                emails = try await appState.fetchEmailsForReview(accountId: accountId)
            } else {
                emails = try await appState.fetchEmailsByTier(accountId: accountId, tier: tier)
            }
        } catch {
            print("Failed to load emails by tier: \(error)")
        }
    }
}

// MARK: - Similar Emails View

struct SimilarEmailsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let sourceEmail: EmailMetadata

    @State private var similarEmails: [EmailMetadata] = []
    @State private var selectedIds: Set<String> = []
    @State private var isLoading = true
    @State private var actionCompleted = false
    @State private var actionMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text("Find Similar Emails")
                    .font(.title2)
                    .fontWeight(.semibold)

                HStack {
                    Text("Subject:")
                        .foregroundStyle(.secondary)
                    Text(sourceEmail.subject)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
                .font(.callout)

                Text("\(similarEmails.count) emails found with this exact subject")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            // Email list with selection
            if isLoading {
                ProgressView("Searching...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if similarEmails.isEmpty {
                Text("No similar emails found")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Select all toggle
                HStack {
                    Button(selectedIds.count == similarEmails.count ? "Deselect All" : "Select All") {
                        if selectedIds.count == similarEmails.count {
                            selectedIds.removeAll()
                        } else {
                            selectedIds = Set(similarEmails.map(\.messageId))
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)

                    Spacer()

                    Text("\(selectedIds.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)

                Divider()

                // Email table
                List(similarEmails, id: \.messageId, selection: $selectedIds) { email in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(email.sender)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Text(email.senderEmail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(minWidth: 150, alignment: .leading)

                        Spacer()

                        Text(email.subject)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 200, alignment: .leading)

                        Spacer()

                        Text(email.date, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(email.messageId)
                }

                Divider()
            }

            // Action bar
            if actionCompleted {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(actionMessage)
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
            } else if !similarEmails.isEmpty {
                HStack {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)

                    Spacer()

                    Button {
                        Task { await markForArchive() }
                    } label: {
                        Label("Archive \(selectedIds.count)", systemImage: "archivebox")
                    }
                    .buttonStyle(.bordered)
                    .disabled(selectedIds.isEmpty)

                    Button {
                        Task { await markForDeletion() }
                    } label: {
                        Label("Delete \(selectedIds.count)", systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(selectedIds.isEmpty)
                }
                .padding()
            } else {
                HStack {
                    Spacer()
                    Button("Close") { dismiss() }
                        .buttonStyle(.bordered)
                }
                .padding()
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .task {
            await loadSimilar()
        }
    }

    private func loadSimilar() async {
        isLoading = true
        defer { isLoading = false }
        guard let account = appState.selectedAccount, let accountId = account.id else { return }
        do {
            similarEmails = try await appState.findSimilarBySubject(accountId: accountId, subject: sourceEmail.subject)
            // Select all by default
            selectedIds = Set(similarEmails.map(\.messageId))
        } catch {
            print("Failed to find similar: \(error)")
        }
    }

    private func markForDeletion() async {
        guard let account = appState.selectedAccount, let accountId = account.id else { return }
        do {
            try await appState.markEmailsForDeletion(messageIds: Array(selectedIds), accountId: accountId)
            actionCompleted = true
            actionMessage = "\(selectedIds.count) emails marked for deletion"
        } catch {
            print("Failed to mark for deletion: \(error)")
        }
    }

    private func markForArchive() async {
        guard let account = appState.selectedAccount, let accountId = account.id else { return }
        do {
            try await appState.markEmailsForArchive(messageIds: Array(selectedIds), accountId: accountId)
            actionCompleted = true
            actionMessage = "\(selectedIds.count) emails marked for archive"
        } catch {
            print("Failed to mark for archive: \(error)")
        }
    }
}
