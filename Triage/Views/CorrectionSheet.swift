import SwiftUI
import TriageCore

/// Fix a categorization the app got wrong.
///
/// Reachable from any email row, because that is where the user notices the mistake. A
/// correction surface that lives only in a settings screen is one nobody finds at the
/// moment they need it.
///
/// Shows what the app decided and why before asking what it should have said. The user is
/// being asked to overrule a judgement, which is easier to do well when the judgement is
/// visible — and seeing the reason is often what explains the error ("Gmail filed it under
/// Promotions" tells them something the category alone does not).
struct CorrectionSheet: View {
    let email: EmailMetadata
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var category: EmailCategory
    @State private var mustKeep: Bool
    @State private var scope: Scope = .wholeSender
    @State private var subjectPattern: String = ""
    @State private var isSaving = false
    /// How many of this sender's emails the current pattern matches, out of how many exist.
    @State private var reach: (matching: Int, total: Int)?

    private var reachDescription: String {
        guard subjectPattern.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else {
            return "Type at least 3 characters."
        }
        guard let reach else { return "Checking how many emails this matches…" }
        if reach.matching == 0 {
            return "Matches none of this sender's \(reach.total) emails — check the spelling."
        }
        if reach.matching == 1 {
            return "Matches 1 of \(reach.total) — just this email. Delete words to cover more."
        }
        return "Matches \(reach.matching) of this sender's \(reach.total) emails."
    }

    private func updateReach() async {
        let pattern = subjectPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pattern.count >= 3 else {
            reach = nil
            return
        }
        reach = await appState.subjectPatternReach(
            senderEmail: email.senderEmail,
            subjectPattern: pattern,
            accountId: email.accountId
        )
    }

    /// How wide the correction should reach.
    private enum Scope: String, CaseIterable, Identifiable {
        case wholeSender
        case matchingSubjects

        var id: String { rawValue }

        var label: String {
            switch self {
            case .wholeSender: return "All mail from this sender"
            case .matchingSubjects: return "Only subjects containing…"
            }
        }
    }

    init(email: EmailMetadata) {
        self.email = email
        // Start from what the app currently thinks, so a user who only wants to change the
        // keep/discard decision does not have to re-pick a category that was already right.
        _category = State(initialValue: email.category ?? .unknown)
        _mustKeep = State(initialValue: email.safetyTier != .safe)

        // Prefilled with THIS email's subject, and scoped to matching subjects by default.
        //
        // Opening this sheet from a row means "act on this email", and the previous default
        // made that the long way round: pick the scope, then retype what was already on screen.
        // Prefilling a field that is hidden until you switch scope would be pointless, so the
        // scope moves with it.
        //
        // The full subject is a deliberately NARROW starting point — it matches this email and
        // its exact repeats, which is what acting on one email means. Widening is a matter of
        // deleting words, and the reach line below reports what each deletion buys.
        _subjectPattern = State(initialValue: email.subject)
        _scope = State(initialValue: .matchingSubjects)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            currentVerdict
            Divider()
            correctedVerdict
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(width: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Correct this categorization")
                .font(.headline)
            Text(email.subject)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
            Text(email.senderEmail)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    private var currentVerdict: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The app said")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text((email.category ?? .unknown).displayName)
                    .font(.callout.weight(.medium))
                if let tier = email.safetyTier {
                    Text(tier.displayName)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(tierColor(tier).opacity(0.15), in: Capsule())
                        .foregroundStyle(tierColor(tier))
                }
            }

            // The reason is the most useful thing on this sheet: it usually explains the
            // mistake, and it is what tells the user whether the fix should be narrow.
            if let reason = email.categoryReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if let provider = email.providerCategory {
                Text("Gmail filed it under \(provider.displayName)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var correctedVerdict: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("It should be")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("Category", selection: $category) {
                ForEach(EmailCategory.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.menu)

            // Asked separately from the category on purpose: "promotional but I want to
            // keep it" is a real and common position, and collapsing the two questions
            // would force the user to mislabel one to get the other right.
            Toggle(isOn: $mustKeep) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Never delete this automatically")
                    Text("Keeps it out of every cleanup plan, whatever the category.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Applies to", selection: $scope) {
                ForEach(Scope.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.radioGroup)

            if scope == .matchingSubjects {
                TextField("e.g. jaarafrekening", text: $subjectPattern)
                    .textFieldStyle(.roundedBorder)

                // Live reach, because a pattern is a rule for mail that has not arrived yet and
                // whether it generalises is invisible while typing. The full subject matches one
                // email; deleting words until this number climbs is how a rule gets made, and
                // seeing it climb is what teaches that.
                Text(reachDescription)
                    .font(.caption)
                    .foregroundStyle(reach.map { $0.matching > 1 } == true ? .green : .secondary)
                    .task(id: subjectPattern) {
                        // Debounced: this runs on every keystroke.
                        try? await Task.sleep(for: .milliseconds(200))
                        guard !Task.isCancelled else { return }
                        await updateReach()
                    }

                Text(
                    "Use this when a sender mixes mail you want with mail you don't — "
                        + "a rail operator sending both offers and tickets, for example."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Text(
                "This also teaches the classifier: it's applied to this sender's mail now, "
                    + "and used as an example when judging senders you haven't corrected."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            if let status = appState.correctionStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isSaving ? "Saving…" : "Save correction") {
                Task {
                    isSaving = true
                    await appState.correctCategory(
                        for: email,
                        to: category,
                        mustKeep: mustKeep,
                        scopeToSubjectPattern: scope == .matchingSubjects ? subjectPattern : nil
                    )
                    isSaving = false
                    dismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(isSaving || (scope == .matchingSubjects && subjectPattern.count < 3))
        }
    }

    private func tierColor(_ tier: SafetyTier) -> Color {
        switch tier {
        case .safe: return .orange
        case .review: return .blue
        case .protected_: return .green
        }
    }
}
