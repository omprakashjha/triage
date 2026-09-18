import Foundation

// MARK: - Action Plan

/// A complete action plan for cleaning up an account
public struct ActionPlan: Sendable {
    public let accountId: Int64
    public let generatedAt: Date
    public let items: [ActionPlanItem]
    public let summary: ActionPlanSummary

    public init(accountId: Int64, generatedAt: Date, items: [ActionPlanItem], summary: ActionPlanSummary) {
        self.accountId = accountId
        self.generatedAt = generatedAt
        self.items = items
        self.summary = summary
    }

    /// All message IDs grouped by action for execution
    public var actionsByType: [EmailAction: [String]] {
        var result: [EmailAction: [String]] = [:]
        for item in items where item.isApproved {
            for entry in item.entries {
                result[item.action, default: []].append(entry.messageId)
            }
        }
        return result
    }

    /// Total emails that will be acted upon
    public var totalApproved: Int {
        items.filter(\.isApproved).reduce(0) { $0 + $1.approvedCount }
    }
}

/// A single line item in the action plan (one category + action combination)
public struct ActionPlanItem: Identifiable, Sendable {
    public let id: String
    public let category: EmailCategory
    public let action: EmailAction
    public let entries: [ActionPlanEntry]
    public var isApproved: Bool
    /// Messages the user has taken OUT of this item, by message id.
    ///
    /// Approval was previously all-or-nothing per item, so the smallest thing this app could execute
    /// was a whole category — which meant its first ever deletion would have been forty-four
    /// messages at once, on a code path that had never run, with an undo that had never run either.
    /// Excluding by id lets the same plan be executed for one sender first.
    ///
    /// Empty by default, so an item built without touching this behaves exactly as before.
    public var excludedMessageIds: Set<String>
    public let ageFilter: Int?  // Only include emails older than N days (nil = all)
    public let reason: String

    public init(
        id: String,
        category: EmailCategory,
        action: EmailAction,
        entries: [ActionPlanEntry],
        isApproved: Bool,
        excludedMessageIds: Set<String> = [],
        ageFilter: Int? = nil,
        reason: String = ""
    ) {
        self.id = id
        self.category = category
        self.action = action
        self.entries = entries
        self.isApproved = isApproved
        self.excludedMessageIds = excludedMessageIds
        self.ageFilter = ageFilter
        self.reason = reason
    }

    /// The entries that would actually be acted on.
    ///
    /// Everything that executes MUST read this rather than `entries`. A UI that lets the user
    /// deselect mail while the executor still reads the full list would be worse than having no
    /// selection at all, because it would silently delete what the user had just excluded.
    public var approvedEntries: [ActionPlanEntry] {
        guard !excludedMessageIds.isEmpty else { return entries }
        return entries.filter { !excludedMessageIds.contains($0.messageId) }
    }

    /// How many messages this item would act on, after exclusions.
    public var approvedCount: Int { approvedEntries.count }

    /// Whether the user has excluded everything, leaving an approved item with nothing to do.
    public var isEffectivelyEmpty: Bool { isApproved && approvedEntries.isEmpty }

    public var emailCount: Int { entries.count }

    /// Grouped by sender for drill-down view
    public var senderBreakdown: [(sender: String, email: String, count: Int)] {
        var map: [String: (name: String, count: Int)] = [:]
        for entry in entries {
            map[entry.senderEmail, default: (entry.sender, 0)].count += 1
        }
        return map.map { (sender: $0.value.name, email: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }
}

/// A single email entry within a plan item
public struct ActionPlanEntry: Sendable {
    public let messageId: String
    public let sender: String
    public let senderEmail: String
    public let subject: String
    public let date: Date

    public init(messageId: String, sender: String = "", senderEmail: String = "", subject: String = "", date: Date = Date()) {
        self.messageId = messageId
        self.sender = sender
        self.senderEmail = senderEmail
        self.subject = subject
        self.date = date
    }
}

/// Summary statistics for the plan
public struct ActionPlanSummary: Sendable {
    public let totalEmails: Int
    public let toArchive: Int
    public let toDelete: Int
    public let toSkip: Int
    public let protectedCount: Int

    public init(totalEmails: Int, toArchive: Int, toDelete: Int, toSkip: Int = 0, protectedCount: Int = 0) {
        self.totalEmails = totalEmails
        self.toArchive = toArchive
        self.toDelete = toDelete
        self.toSkip = toSkip
        self.protectedCount = protectedCount
    }
}

// MARK: - Action Rules

/// Configurable rules that determine what action to take per category
public struct ActionRules: Codable, Sendable, Equatable {
    public var newsletterAction: EmailAction
    public var newsletterMaxAgeDays: Int?

    public var promotionAction: EmailAction
    public var promotionMaxAgeDays: Int?

    public var notificationAction: EmailAction
    public var notificationMaxAgeDays: Int?

    public var socialAction: EmailAction
    public var socialMaxAgeDays: Int?

    public var transactionalAction: EmailAction
    public var transactionalMaxAgeDays: Int?

    public var personalAction: EmailAction
    public var unknownAction: EmailAction

    /// Default rules — conservative but effective
    public static let `default` = ActionRules(
        newsletterAction: .archived,
        newsletterMaxAgeDays: nil,         // Archive all newsletters
        promotionAction: .deleted,
        promotionMaxAgeDays: 30,           // Delete promotions older than 30 days
        notificationAction: .deleted,
        notificationMaxAgeDays: 30,        // Delete notifications older than 30 days
        socialAction: .archived,
        socialMaxAgeDays: 60,              // Archive social older than 60 days
        transactionalAction: .archived,
        transactionalMaxAgeDays: 90,       // Archive transactional older than 90 days
        personalAction: .skipped,          // Never touch personal
        unknownAction: .skipped            // Never auto-touch unknown
    )

    /// Aggressive rules for maximum cleanup
    public static let aggressive = ActionRules(
        newsletterAction: .deleted,
        newsletterMaxAgeDays: 7,
        promotionAction: .deleted,
        promotionMaxAgeDays: 7,
        notificationAction: .deleted,
        notificationMaxAgeDays: 7,
        socialAction: .deleted,
        socialMaxAgeDays: 30,
        transactionalAction: .archived,
        transactionalMaxAgeDays: 30,
        personalAction: .skipped,
        unknownAction: .skipped
    )

    func actionFor(category: EmailCategory) -> EmailAction {
        switch category {
        case .newsletter: return newsletterAction
        case .promotion: return promotionAction
        case .notification: return notificationAction
        case .social: return socialAction
        case .transactional: return transactionalAction
        case .personal: return personalAction
        case .unknown: return unknownAction
        }
    }

    func maxAgeDaysFor(category: EmailCategory) -> Int? {
        switch category {
        case .newsletter: return newsletterMaxAgeDays
        case .promotion: return promotionMaxAgeDays
        case .notification: return notificationMaxAgeDays
        case .social: return socialMaxAgeDays
        case .transactional: return transactionalMaxAgeDays
        case .personal: return nil
        case .unknown: return nil
        }
    }
}

// MARK: - Action Planner

/// Generates an action plan from categorized emails based on configurable rules
public struct ActionPlanner: Sendable {
    private let rules: ActionRules

    public init(rules: ActionRules = .default) {
        self.rules = rules
    }

    /// Generate an action plan for all categorized emails in an account
    public func generatePlan(emails: [EmailMetadata], accountId: Int64) -> ActionPlan {
        let now = Date()
        var items: [ActionPlanItem] = []

        // Group emails by category
        var byCategory: [EmailCategory: [EmailMetadata]] = [:]
        for email in emails {
            guard let category = email.category else { continue }
            // Skip protected emails
            if email.safetyTier == .protected_ { continue }
            byCategory[category, default: []].append(email)
        }

        // Generate plan items per category
        for category in EmailCategory.allCases {
            guard let categoryEmails = byCategory[category], !categoryEmails.isEmpty else { continue }

            let action = rules.actionFor(category: category)
            guard action != .skipped else { continue }  // Don't include skip items

            let maxAgeDays = rules.maxAgeDaysFor(category: category)

            // Filter by age if specified
            let eligibleEmails: [EmailMetadata]
            if let maxDays = maxAgeDays {
                let cutoff = now.addingTimeInterval(-Double(maxDays) * 86400)
                eligibleEmails = categoryEmails.filter { $0.date < cutoff }
            } else {
                eligibleEmails = categoryEmails
            }

            guard !eligibleEmails.isEmpty else { continue }

            // Split by tier before building items.
            //
            // Approval was previously all-or-nothing across a whole category: `allSatisfy { tier
            // == .safe }` meant ONE review-tier message withheld every safe message beside it.
            // Measured on a real mailbox that cost 122 of 181 safe emails — 54 safe promotions were
            // held by 16 review siblings, 61 safe newsletters by 2, 7 safe transactional by 1 — and
            // notification was the only category with no review mail, which is why it was the only
            // one ever acted on.
            //
            // Splitting changes no safety property. Review-tier mail is still not approved; it is
            // simply no longer able to veto mail that was cleared on its own evidence.
            let safeEmails = eligibleEmails.filter { $0.safetyTier == .safe }
            let unclearedEmails = eligibleEmails.filter { $0.safetyTier != .safe }

            func makeEntries(_ list: [EmailMetadata]) -> [ActionPlanEntry] {
                list.map { email in
                    ActionPlanEntry(
                        messageId: email.messageId,
                        sender: email.sender,
                        senderEmail: email.senderEmail,
                        subject: email.subject,
                        date: email.date
                    )
                }
            }

            // The cleared subset: auto-approved, exactly as before, but no longer contingent on its
            // siblings.
            if !safeEmails.isEmpty {
                items.append(ActionPlanItem(
                    id: "\(category.rawValue)_\(action.rawValue)",
                    category: category,
                    action: action,
                    entries: makeEntries(safeEmails),
                    isApproved: category != .unknown,
                    ageFilter: maxAgeDays,
                    reason: buildReason(category: category, action: action, ageDays: maxAgeDays)
                ))
            }

            // The undecided subset: present so the user can see and approve it deliberately, never
            // pre-approved. Kept as its own item rather than dropped, because silently omitting mail
            // the engine could not judge would hide the work still outstanding.
            if !unclearedEmails.isEmpty {
                items.append(ActionPlanItem(
                    id: "\(category.rawValue)_\(action.rawValue)_needsReview",
                    category: category,
                    action: action,
                    entries: makeEntries(unclearedEmails),
                    isApproved: false,
                    ageFilter: maxAgeDays,
                    reason: buildReason(category: category, action: action, ageDays: maxAgeDays)
                        + " — not yet cleared, approve only if you agree"
                ))
            }
            continue
        }

        // Calculate summary
        let protectedCount = emails.filter { $0.safetyTier == .protected_ }.count
        let toArchive = items.filter { $0.isApproved && $0.action == .archived }.reduce(0) { $0 + $1.approvedCount }
        let toDelete = items.filter { $0.isApproved && $0.action == .deleted }.reduce(0) { $0 + $1.approvedCount }
        let toSkip = emails.count - toArchive - toDelete

        let summary = ActionPlanSummary(
            totalEmails: emails.count,
            toArchive: toArchive,
            toDelete: toDelete,
            toSkip: toSkip,
            protectedCount: protectedCount
        )

        return ActionPlan(
            accountId: accountId,
            generatedAt: now,
            items: items.sorted { $0.emailCount > $1.emailCount },
            summary: summary
        )
    }

    private func buildReason(category: EmailCategory, action: EmailAction, ageDays: Int?) -> String {
        let actionName = action == .archived ? "Archive" : action == .deleted ? "Delete" : "Process"
        let ageStr = ageDays.map { " older than \($0) days" } ?? ""
        return "\(actionName) \(category.displayName)\(ageStr)"
    }
}
