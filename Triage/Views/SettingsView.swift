import SwiftUI
import TriageCore
import TriageBedrock

/// Scan scope, per-category action rules, and the standing sender rules.
///
/// `ActionRules` has always been `Codable` but was never persisted or editable —
/// every plan used the hardcoded `.default`. This is where that becomes real.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                scanScopeSection
                Divider()
                actionRulesSection
                Divider()
                senderRulesSection
                Divider()
                aiSection
                Divider()
                maintenanceSection
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .task(id: appState.selectedAccount?.id) {
            if let accountId = appState.selectedAccount?.id {
                await appState.loadSettings(accountId: accountId)
                await appState.loadSenderRules(accountId: accountId)
            }
        }
    }

    // MARK: - Scan scope

    private var scanScopeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scan scope")
                .font(.headline)
            Text("What a scan looks at. Everything the app reports — counts, categories, plans — describes only what was scanned.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(ScanScope.allCases, id: \.self) { scope in
                Button {
                    Task {
                        if let accountId = appState.selectedAccount?.id {
                            await appState.updateScanScope(scope, accountId: accountId)
                        }
                    }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: currentScope == scope ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(currentScope == scope ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(scope.displayName)
                            Text(scope.explanation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Text("Changing scope affects the next scan. A wider scope needs a full rescan, not an incremental one.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var currentScope: ScanScope {
        appState.settings?.scanScope ?? .unreadOnly
    }

    // MARK: - Action rules

    private var actionRulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Default action per category")
                .font(.headline)
            Text("Used when generating an action plan. Only mail in the Safe tier is ever pre-approved.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Use conservative defaults") {
                    Task { await apply(.default) }
                }
                .buttonStyle(.bordered)

                Button("Use aggressive preset") {
                    Task { await apply(.aggressive) }
                }
                .buttonStyle(.bordered)
            }

            if let rules = appState.settings?.actionRules {
                VStack(alignment: .leading, spacing: 4) {
                    ruleRow("Newsletters", rules.newsletterAction, rules.newsletterMaxAgeDays)
                    ruleRow("Promotions", rules.promotionAction, rules.promotionMaxAgeDays)
                    ruleRow("Notifications", rules.notificationAction, rules.notificationMaxAgeDays)
                    ruleRow("Social", rules.socialAction, rules.socialMaxAgeDays)
                    ruleRow("Transactional", rules.transactionalAction, rules.transactionalMaxAgeDays)
                    ruleRow("Personal", rules.personalAction, nil)
                    ruleRow("Unknown", rules.unknownAction, nil)
                }
                .padding(.top, 4)
            }
        }
    }

    private func ruleRow(_ label: String, _ action: EmailAction, _ ageDays: Int?) -> some View {
        HStack {
            Text(label)
                .frame(width: 120, alignment: .leading)
            Text(action.rawValue.capitalized)
                .foregroundStyle(action == .deleted ? .red : action == .skipped ? .secondary : .blue)
            if let ageDays {
                Text("older than \(ageDays)d")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.caption)
    }

    private func apply(_ rules: ActionRules) async {
        guard let accountId = appState.selectedAccount?.id else { return }
        await appState.updateActionRules(rules, accountId: accountId)
    }

    // MARK: - Sender rules

    private var senderRulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Standing sender rules")
                .font(.headline)
            Text("Applied automatically after every scan. Protected contacts are never affected, whatever a rule says.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if appState.senderRules.isEmpty {
                Text("No rules yet. Decide a sender in the Senders view and tick “do this automatically”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(appState.senderRules) { rule in
                    HStack {
                        Image(systemName: rule.action == .deleted ? "trash" : "archivebox")
                            .foregroundStyle(rule.action == .deleted ? .red : .blue)
                            .font(.caption)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(rule.pattern)
                                .fontWeight(.medium)
                            Text("\(rule.scope.displayName) • \(rule.action.rawValue)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button(rule.isEnabled ? "Disable" : "Enable") {
                            Task {
                                if let accountId = appState.selectedAccount?.id {
                                    await appState.toggleSenderRule(rule, accountId: accountId)
                                }
                            }
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)

                        Button(role: .destructive) {
                            Task {
                                if let accountId = appState.selectedAccount?.id {
                                    await appState.deleteSenderRule(rule, accountId: accountId)
                                }
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .opacity(rule.isEnabled ? 1 : 0.5)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - AI

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cloud categorization (optional)")
                .font(.headline)

            Text("Everything else in this app runs locally. Turning this on is the only thing that sends data off your machine, so it is off by default.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Use Amazon Bedrock for senders the local rules cannot resolve", isOn: Binding(
                get: { appState.settings?.aiConfig.isEnabled ?? false },
                set: { newValue in
                    Task {
                        guard let accountId = appState.selectedAccount?.id else { return }
                        var config = appState.settings?.aiConfig ?? AIConfig()
                        config.isEnabled = newValue
                        await appState.updateAIConfig(config, accountId: accountId)
                    }
                }
            ))

            // Stated plainly rather than buried: the user is agreeing to specific egress.
            DisclosureGroup("What gets sent") {
                Text(AIConfig.egressDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .font(.caption)

            if appState.settings?.aiConfig.isEnabled == true {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Model") {
                        TextField(
                            BedrockLLMTransport.defaultModelId,
                            text: Binding(
                                get: { appState.settings?.aiConfig.modelId ?? "" },
                                set: { newValue in
                                    Task {
                                        guard let accountId = appState.selectedAccount?.id else { return }
                                        var config = appState.settings?.aiConfig ?? AIConfig()
                                        config.modelId = newValue
                                        await appState.updateAIConfig(config, accountId: accountId)
                                    }
                                }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                    }

                    LabeledContent("Region") {
                        TextField(
                            "leave blank to use your AWS profile's region",
                            text: Binding(
                                get: { appState.settings?.aiConfig.region ?? "" },
                                set: { newValue in
                                    Task {
                                        guard let accountId = appState.selectedAccount?.id else { return }
                                        var config = appState.settings?.aiConfig ?? AIConfig()
                                        config.region = newValue
                                        await appState.updateAIConfig(config, accountId: accountId)
                                    }
                                }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                    }

                    Text("Blank region means your AWS profile decides. Setting it here overrides the profile, which is rarely what you want. An app launched from Finder cannot see AWS_PROFILE, so the profile must be named `default`.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        Task {
                            if let accountId = appState.selectedAccount?.id {
                                await appState.testAIConnection(accountId: accountId)
                            }
                        }
                    } label: {
                        if appState.isTestingAI {
                            ProgressView().controlSize(.small)
                            Text("Testing…")
                        } else {
                            Label("Test connection", systemImage: "bolt.horizontal")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(appState.isTestingAI)

                    Text("Sends one synthetic sender. Listing models is not proof — a model can appear in the catalogue and still reject the forced tool call this depends on.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 20)
            }

            if let message = appState.aiStatusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(message.hasPrefix("Connected") ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Label(
                "A model verdict can only ever make mail safer. Moving mail toward deletion always requires the local rules to agree.",
                systemImage: "lock.shield"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Maintenance

    private var maintenanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Maintenance")
                .font(.headline)

            Text("Mail categorized before your contact list existed was judged without it. Re-running categorization applies the current contacts and rules to everything.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    Task {
                        if let accountId = appState.selectedAccount?.id {
                            await appState.recategorizeAll(accountId: accountId)
                            await appState.applySenderRules(accountId: accountId)
                        }
                    }
                } label: {
                    if appState.isRecategorizing {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small)
                            Text("Working…")
                        }
                    } else {
                        Text("Re-categorize all mail")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.isRecategorizing || appState.selectedAccount == nil)

                Button("Re-apply sender rules") {
                    Task {
                        if let accountId = appState.selectedAccount?.id {
                            await appState.applySenderRules(accountId: accountId)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(appState.isRecategorizing)
            }

            if appState.selectedAccount == nil {
                Text("Select an account in the sidebar first — these act on one account.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            // Outcome, stated explicitly. Previously this ran and reported nothing at
            // all, so a successful run and a dead button looked identical.
            if let status = appState.maintenanceStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(status.contains("failed") ? .red : .secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if appState.lastRuleMatchCount > 0 {
                Text("\(appState.lastRuleMatchCount) emails marked by standing rules.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Label(
                "\(appState.knownContactCount) protected contacts",
                systemImage: "person.crop.circle.badge.checkmark"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
