import SwiftUI
import TriageCore

/// Shows the category breakdown after scanning and categorization
struct CategoryBreakdownView: View {
    @EnvironmentObject private var appState: AppState
    let stats: AccountStats

    /// What the left list has selected — a category OR a tier, never both and never neither
    /// tracked separately.
    ///
    /// Two optionals plus an `.onTapGesture` is what this was, and it is the same defect shape as
    /// the sidebar: the tier rows wrote BOTH `selectedCategory = nil` and `selectedTier = …` from
    /// a tap gesture living inside a selection-bound List, so one click drove the List's own
    /// selection machinery and two state writes at once. HSplitView then rebuilt both panes and
    /// collapsed the left one. Category rows used the native `.tag` path and were unaffected,
    /// which is exactly the asymmetry the user reported.
    ///
    /// One value, set only through the List's selection binding, means one mechanism and a right
    /// pane that is a pure function of it.
    private enum Selection: Hashable {
        case category(EmailCategory)
        case tier(SafetyTier)
    }

    @State private var selection: Selection?

    var body: some View {
        HSplitView {
            categoryList
                .frame(minWidth: 250, maxWidth: 350)

            // A minimum width on the detail side too. HSplitView distributes space when its
            // children change, and a detail view with no floor can take the whole width.
            switch selection {
            case .category(let category):
                EmailListView(category: category)
                    .frame(minWidth: 420)
            case .tier(let tier):
                TierEmailListView(tier: tier)
                    .frame(minWidth: 420)
            case nil:
                VStack {
                    Image(systemName: "envelope.open")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Select a category to view emails")
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
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
            List(selection: $selection) {
                Section("Categories") {
                    ForEach(sortedCategories, id: \.category) { item in
                        CategoryRow(
                            category: item.category,
                            count: item.count,
                            percentage: Double(item.count) / Double(max(stats.totalEmails, 1))
                        )
                        .tag(Selection.category(item.category))
                    }
                }

                Section("Safety Tiers") {
                    // Tagged, exactly like the category rows. These previously used
                    // `.onTapGesture` to write two separate selections, which competed with the
                    // List's own selection handling and collapsed the split view's left pane.
                    TierRow(tier: .safe, count: stats.tierBreakdown[.safe] ?? 0)
                        .tag(Selection.tier(.safe))
                    TierRow(tier: .review, count: stats.tierBreakdown[.review] ?? 0)
                        .tag(Selection.tier(.review))
                    TierRow(tier: .protected_, count: stats.tierBreakdown[.protected_] ?? 0)
                        .tag(Selection.tier(.protected_))
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
    /// Local @State, deliberately not a @Published on AppState.
    ///
    /// A List whose selection binding writes shared observable state, in a view that also
    /// mutates other observable state on the same tap, is what emptied the sidebar last night.
    /// Selection that nothing outside this screen needs has no business leaving it.
    @State private var selectedMessageId: String?
    @State private var hoveredMessageId: String?
    /// Message ids decided on this screen, which no reload may bring back.
    @State private var decidedMessageIds: Set<String> = []
    /// Guards against an older load applying its result after a newer one started.
    @State private var loadGeneration = 0
    /// Per-row outcome text, for decisions that correctly leave the row where it is.
    @State private var confirmations: [String: String] = [:]

    @EnvironmentObject private var appState: AppState
    let tier: SafetyTier

    @State private var emails: [EmailMetadata] = []
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
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
                // Stated, because a gesture nobody knows about is not a feature. The keyboard
                // path is the fast one once known, so it is named here too.
                if !emails.isEmpty {
                    Text("Drag a row right to keep, left to mark it deletable — or select one and press K or D. Either applies to every email from the same sender with the same subject.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // The outcome of a decision, shown HERE. It was already being recorded on
                // AppState and displayed on three other screens but not on the one where the
                // decisions are now made — so a swipe that succeeded and a swipe that silently
                // failed looked identical, which is precisely the ambiguity that makes a UI
                // impossible to trust.
                if let status = appState.correctionStatus {
                    Label(status, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                // A List rather than a Table, because the row needs to move under a gesture and
                // a Table row cannot.
                //
                // The gesture is implemented here rather than with `.swipeActions`, which did
                // nothing on this machine. That modifier is documented as available on macOS but
                // it listens for a two-finger trackpad swipe, which is a SCROLL event — on a
                // mouse, or a trackpad the system reports differently, there is no gesture for it
                // to hear and it silently never fires. A DragGesture responds to press-and-drag,
                // which every pointing device produces.
                //
                // Doing it by hand also buys the thing the modifier could not: the row follows
                // the pointer and names the action it is about to take, so the gesture is
                // discovered by trying it rather than by being told.
                List(emails, id: \.messageId, selection: $selectedMessageId) { email in
                    SwipeableEmailRow(
                        email: email,
                        showsHoverActions: hoveredMessageId == email.messageId,
                        confirmation: confirmations[email.messageId],
                        onKeep: { decide(email, mustKeep: true) },
                        onDelete: { decide(email, mustKeep: false) },
                        onEdit: { correctingEmail = email }
                    )
                    .onHover { hoveredMessageId = $0 ? email.messageId : nil }
                    .contextMenu {
                        Button("Safe to delete — this and its repeats") {
                            decide(email, mustKeep: false)
                        }
                        Button("Keep — this and its repeats") {
                            decide(email, mustKeep: true)
                        }
                        Divider()
                        Button("Correct this categorization…") { correctingEmail = email }
                    }
                }
                .listStyle(.inset)
            }
        }
        // Keyboard shortcuts on hidden buttons, which is how a List row action gets a shortcut:
        // they act on the selected row, so D and K work once a row is selected with the arrows.
        .background {
            VStack {
                Button("") { withSelected { decide($0, mustKeep: false) } }
                    .keyboardShortcut("d", modifiers: [])
                Button("") { withSelected { decide($0, mustKeep: true) } }
                    .keyboardShortcut("k", modifiers: [])
                Button("") { withSelected { correctingEmail = $0 } }
                    .keyboardShortcut(.return, modifiers: [])
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
        .task(id: tier) {
            // A tier switch is a fresh piece of work, so decisions from the previous one stop
            // suppressing rows here — otherwise a decision reversed in Settings could never
            // reappear without relaunching.
            decidedMessageIds = []
            await loadEmails()
        }
        .sheet(item: $correctingEmail) { email in
            CorrectionSheet(email: email)
                .environmentObject(appState)
        }
    }

    private func withSelected(_ action: (EmailMetadata) -> Void) {
        guard let id = selectedMessageId,
              let email = emails.first(where: { $0.messageId == id }) else { return }
        action(email)
    }

    /// Apply a decision to this email and every recurring issue of the same mail.
    private func decide(_ email: EmailMetadata, mustKeep: Bool) {
        // The rows this decision covers are removed straight away, before any await.
        //
        // Waiting for the write and the reload to come back was the reason a decided row sat
        // there: the data was correct within milliseconds — a test now pins that end to end — but
        // the list is only refreshed by an async hop, and anything that delays or reorders that
        // hop leaves the queue displaying mail that has already been decided. Removing locally
        // makes the gesture's effect immediate and independent of that timing, and the reload
        // below still reconciles against the database, so a failed write puts the rows back
        // rather than hiding them.
        let pattern = SubjectStem.decisionPattern(for: email.subject).pattern
        let sender = email.senderEmail.lowercased()
        let decidedTier: SafetyTier = mustKeep ? .protected_ : .safe

        // Only when the decision actually moves mail OUT of the tier being displayed. Deciding
        // safe mail to be deletable leaves it safe, and removing it there then restoring it on
        // reload would be a flicker that misrepresents what happened.
        if decidedTier != tier {
            let doomed = emails.filter {
                $0.senderEmail.lowercased() == sender
                    && SubjectStem.pattern(pattern, matches: $0.subject)
            }
            // Remembered, not just removed. A reload that was already in flight when this drag
            // happened would otherwise put these rows straight back.
            decidedMessageIds.formUnion(doomed.map(\.messageId))
            withAnimation(.easeOut(duration: 0.2)) {
                emails.removeAll { decidedMessageIds.contains($0.messageId) }
            }
        } else {
            // The decision is real but this tier already reflects it, so the rows stay. Say so on
            // the rows themselves — silence here reads as a failed gesture, which is the worst
            // possible reading for a control that decides whether mail gets deleted.
            let staying = emails.filter {
                $0.senderEmail.lowercased() == sender
                    && SubjectStem.pattern(pattern, matches: $0.subject)
            }
            let label = mustKeep ? "Kept" : "Marked deletable"
            withAnimation(.easeOut(duration: 0.15)) {
                for m in staying { confirmations[m.messageId] = label }
            }
            let ids = staying.map(\.messageId)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                withAnimation { for id in ids { confirmations.removeValue(forKey: id) } }
            }
        }

        // @MainActor explicitly: this mutates view state, and a bare Task inherits whatever
        // context the gesture handler happened to run on.
        Task { @MainActor in
            await appState.decideEmailAndItsRepeats(email, mustKeep: mustKeep)
            await loadEmails(showingProgress: false)
        }
    }

    private var tierColor: Color {
        switch tier {
        case .safe: return .green
        case .review: return .orange
        case .protected_: return .blue
        }
    }

    @MainActor
    private func loadEmails(showingProgress: Bool = true) async {
        if showingProgress { isLoading = true }
        defer { if showingProgress { isLoading = false } }
        guard let account = appState.selectedAccount, let accountId = account.id else { return }

        // Each load claims a generation. An older load that finishes after a newer one started is
        // discarded rather than applied: without this, the reload from drag 1 lands after drag 2
        // has already removed its rows and overwrites the list with database contents that still
        // contain them, because drag 2's write has not committed yet. That is precisely why the
        // first drag appeared to work and the ones after it did not.
        loadGeneration += 1
        let generation = loadGeneration

        do {
            // The review tier is a work queue, so order it weakest-confidence first.
            // Other tiers are reference lists and stay newest-first.
            let fetched: [EmailMetadata]
            if tier == .review {
                fetched = try await appState.fetchEmailsForReview(accountId: accountId)
            } else {
                fetched = try await appState.fetchEmailsByTier(accountId: accountId, tier: tier)
            }
            guard generation == loadGeneration else { return }
            // Anything decided on this screen stays gone even if a write is still in flight, so a
            // row can never flicker back after the user has already dealt with it.
            emails = fetched.filter { !decidedMessageIds.contains($0.messageId) }
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
