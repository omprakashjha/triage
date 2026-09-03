import XCTest
@testable import TriageCore

final class SenderTriageTests: XCTestCase {

    private func seed(
        _ db: AppDatabase,
        _ specs: [(sender: String, count: Int, unread: Bool, unsubscribe: Bool, daysAgo: Double)]
    ) async throws -> Int64 {
        var account = EmailAccount(email: "me@example.com", provider: .gmail, createdAt: Date())
        try await db.saveAccount(&account)
        let accountId = account.id!

        var emails: [EmailMetadata] = []
        for spec in specs {
            for i in 0..<spec.count {
                emails.append(
                    EmailMetadata(
                        accountId: accountId,
                        messageId: "\(spec.sender)-\(i)",
                        sender: "Display \(spec.sender)",
                        senderEmail: spec.sender,
                        subject: "Subject \(i)",
                        date: Date().addingTimeInterval(-(spec.daysAgo + Double(i)) * 86400),
                        hasListUnsubscribe: spec.unsubscribe,
                        isUnread: spec.unread,
                        category: .promotion,
                        safetyTier: .safe,
                        categoryConfidence: 0.85
                    )
                )
            }
        }
        try await db.batchUpsertEmails(emails)
        return accountId
    }

    // MARK: - Aggregation

    func testSenderSummariesAggregateAndSortByVolume() async throws {
        let db = try AppDatabase.inMemory()
        let accountId = try await seed(db, [
            (sender: "big@shop.com", count: 5, unread: true, unsubscribe: true, daysAgo: 1),
            (sender: "small@blog.com", count: 2, unread: false, unsubscribe: false, daysAgo: 10),
        ])

        let summaries = try await db.senderSummaries(accountId: accountId)

        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries[0].senderEmail, "big@shop.com")
        XCTAssertEqual(summaries[0].totalEmails, 5)
        XCTAssertEqual(summaries[0].unreadEmails, 5)
        XCTAssertTrue(summaries[0].hasUnsubscribeOption)
        XCTAssertEqual(summaries[0].dominantCategory, .promotion)
        XCTAssertTrue(summaries[0].isUnreadHeavy)

        XCTAssertEqual(summaries[1].totalEmails, 2)
        XCTAssertFalse(summaries[1].hasUnsubscribeOption)
    }

    func testKnownContactIsMarkedProtectedInSummary() async throws {
        let db = try AppDatabase.inMemory()
        let accountId = try await seed(db, [
            (sender: "friend@example.com", count: 3, unread: false, unsubscribe: false, daysAgo: 2),
        ])
        try await db.addManualContact(email: "friend@example.com", accountId: accountId)

        let summaries = try await db.senderSummaries(accountId: accountId)
        XCTAssertTrue(summaries[0].isKnownContact)
        XCTAssertTrue(summaries[0].isProtected)
        XCTAssertFalse(summaries[0].looksLikeSubscription, "a contact is never a subscription")
    }

    func testExecutedMailDropsOutOfSenderSummaries() async throws {
        let db = try AppDatabase.inMemory()
        let accountId = try await seed(db, [
            (sender: "gone@shop.com", count: 2, unread: true, unsubscribe: false, daysAgo: 1),
        ])

        try await db.markEmailsExecuted(
            messageIds: ["gone@shop.com-0", "gone@shop.com-1"],
            accountId: accountId,
            action: .deleted
        )

        let summaries = try await db.senderSummaries(accountId: accountId)
        XCTAssertTrue(summaries.isEmpty, "acted-on senders should leave the triage list")
    }

    func testKeepNewestExcludesTheMostRecent() async throws {
        let db = try AppDatabase.inMemory()
        let accountId = try await seed(db, [
            (sender: "bulk@shop.com", count: 5, unread: true, unsubscribe: false, daysAgo: 1),
        ])

        let all = try await db.messageIds(accountId: accountId, senderEmail: "bulk@shop.com")
        XCTAssertEqual(all.count, 5)

        let keeping2 = try await db.messageIds(
            accountId: accountId,
            senderEmail: "bulk@shop.com",
            keepNewest: 2
        )
        XCTAssertEqual(keeping2.count, 3)
        // Seeded with increasing daysAgo, so index 0 is newest and must be kept.
        XCTAssertFalse(keeping2.contains("bulk@shop.com-0"))
    }

    func testStrictestTierPrefersProtected() {
        XCTAssertEqual(AppDatabase.strictestTier(in: [.safe, .review, .protected_]), .protected_)
        XCTAssertEqual(AppDatabase.strictestTier(in: [.safe, .review]), .review)
        XCTAssertEqual(AppDatabase.strictestTier(in: [.safe]), .safe)
        XCTAssertNil(AppDatabase.strictestTier(in: []))
    }

    // MARK: - Standing rules

    func testAddressScopedRuleMatchesOnlyThatAddress() {
        let rule = SenderRule(accountId: 1, pattern: "news@shop.com", scope: .address, action: .archived)
        XCTAssertTrue(rule.matches(email(from: "news@shop.com")))
        XCTAssertFalse(rule.matches(email(from: "other@shop.com")))
    }

    func testDomainScopedRuleMatchesSubdomains() {
        let rule = SenderRule(accountId: 1, pattern: "shop.com", scope: .domain, action: .deleted)
        XCTAssertTrue(rule.matches(email(from: "anyone@shop.com")))
        XCTAssertTrue(rule.matches(email(from: "promo@mail.shop.com")))
        XCTAssertFalse(rule.matches(email(from: "someone@notshop.com")), "must not match a suffix collision")
    }

    func testDisabledRuleNeverMatches() {
        let rule = SenderRule(
            accountId: 1, pattern: "shop.com", scope: .domain, action: .deleted, isEnabled: false
        )
        XCTAssertFalse(rule.matches(email(from: "anyone@shop.com")))
    }

    func testRuleAgeFilterOnlyMatchesOlderMail() {
        let rule = SenderRule(
            accountId: 1, pattern: "shop.com", scope: .domain, action: .deleted, minAgeDays: 30
        )
        let recent = email(from: "a@shop.com", daysAgo: 5)
        let old = email(from: "a@shop.com", daysAgo: 60)

        XCTAssertFalse(rule.matches(recent))
        XCTAssertTrue(rule.matches(old))
    }

    func testSavingRuleTwiceReplacesRatherThanStacks() async throws {
        let db = try AppDatabase.inMemory()
        var account = EmailAccount(email: "me@example.com", provider: .gmail, createdAt: Date())
        try await db.saveAccount(&account)
        let accountId = account.id!

        try await db.saveSenderRule(
            SenderRule(accountId: accountId, pattern: "shop.com", scope: .domain, action: .archived)
        )
        try await db.saveSenderRule(
            SenderRule(accountId: accountId, pattern: "shop.com", scope: .domain, action: .deleted)
        )

        let rules = try await db.fetchSenderRules(accountId: accountId)
        XCTAssertEqual(rules.count, 1, "re-deciding a sender must not leave two conflicting rules")
        XCTAssertEqual(rules[0].action, .deleted)
    }

    func testProtectedMailIsExcludedFromRuleCandidates() async throws {
        let db = try AppDatabase.inMemory()
        var account = EmailAccount(email: "me@example.com", provider: .gmail, createdAt: Date())
        try await db.saveAccount(&account)
        let accountId = account.id!

        try await db.batchUpsertEmails([
            EmailMetadata(
                accountId: accountId, messageId: "p", sender: "P", senderEmail: "friend@shop.com",
                subject: "Hi", date: Date(), category: .personal, safetyTier: .protected_
            ),
            EmailMetadata(
                accountId: accountId, messageId: "s", sender: "S", senderEmail: "promo@shop.com",
                subject: "Sale", date: Date(), category: .promotion, safetyTier: .safe
            ),
        ])

        let candidates = try await db.fetchUnmarkedActionableEmails(accountId: accountId)
        XCTAssertEqual(candidates.map(\.messageId), ["s"], "a rule must never be able to action protected mail")
    }

    // MARK: - Settings

    func testSettingsRoundTrip() async throws {
        let db = try AppDatabase.inMemory()
        var account = EmailAccount(email: "me@example.com", provider: .gmail, createdAt: Date())
        try await db.saveAccount(&account)
        let accountId = account.id!

        let defaults = try await db.accountSettings(accountId: accountId)
        XCTAssertEqual(defaults.scanScope, .unreadOnly)
        XCTAssertEqual(defaults.actionRules, .default)

        var updated = defaults
        updated.scanScope = .allMail
        updated.actionRules = .aggressive
        try await db.saveAccountSettings(updated)

        let reloaded = try await db.accountSettings(accountId: accountId)
        XCTAssertEqual(reloaded.scanScope, .allMail)
        XCTAssertEqual(reloaded.actionRules, .aggressive)
    }

    // MARK: - Scan scope

    func testScanScopeQueries() {
        XCTAssertEqual(ScanScope.unreadOnly.gmailQuery, "is:unread")
        XCTAssertEqual(ScanScope.inbox.gmailQuery, "in:inbox")
        XCTAssertEqual(ScanScope.allMail.gmailQuery, "")
    }

    func testScanScopeFiltersIncrementalResults() {
        let now = Date()
        let old = now.addingTimeInterval(-400 * 86400)

        // This is the filter that stops incremental sync from adding mail a full
        // sync would never have fetched.
        XCTAssertTrue(ScanScope.unreadOnly.includes(labelIds: nil, isUnread: true, date: now, now: now))
        XCTAssertFalse(ScanScope.unreadOnly.includes(labelIds: nil, isUnread: false, date: now, now: now))

        XCTAssertTrue(ScanScope.inbox.includes(labelIds: ["INBOX"], isUnread: false, date: now, now: now))
        XCTAssertFalse(ScanScope.inbox.includes(labelIds: ["ARCHIVE"], isUnread: false, date: now, now: now))

        XCTAssertTrue(ScanScope.olderThanOneYear.includes(labelIds: nil, isUnread: false, date: old, now: now))
        XCTAssertFalse(ScanScope.olderThanOneYear.includes(labelIds: nil, isUnread: false, date: now, now: now))

        XCTAssertTrue(ScanScope.allMail.includes(labelIds: nil, isUnread: false, date: now, now: now))
    }

    // MARK: - Tier-gated auto-approval

    func testReviewTierMailIsNotAutoApproved() {
        let planner = ActionPlanner(rules: .default)
        let old = Date().addingTimeInterval(-100 * 86400)

        let reviewEmail = EmailMetadata(
            accountId: 1, messageId: "r", sender: "S", senderEmail: "x@shop.com",
            subject: "Ambiguous", date: old,
            category: .promotion, safetyTier: .review, categoryConfidence: 0.45
        )
        let plan = planner.generatePlan(emails: [reviewEmail], accountId: 1)

        XCTAssertEqual(plan.items.count, 1)
        XCTAssertFalse(
            plan.items[0].isApproved,
            "mail the engine flagged for review must not arrive pre-approved for deletion"
        )
        XCTAssertEqual(plan.totalApproved, 0)
    }

    func testSafeTierMailIsAutoApproved() {
        let planner = ActionPlanner(rules: .default)
        let old = Date().addingTimeInterval(-100 * 86400)

        let safeEmail = EmailMetadata(
            accountId: 1, messageId: "s", sender: "S", senderEmail: "x@shop.com",
            subject: "50% off", date: old,
            category: .promotion, safetyTier: .safe, categoryConfidence: 0.9
        )
        let plan = planner.generatePlan(emails: [safeEmail], accountId: 1)

        XCTAssertTrue(plan.items[0].isApproved)
        XCTAssertEqual(plan.totalApproved, 1)
    }

    // MARK: - Helpers

    private func email(from sender: String, daysAgo: Double = 0) -> EmailMetadata {
        EmailMetadata(
            accountId: 1,
            messageId: "m",
            sender: "S",
            senderEmail: sender,
            subject: "Subject",
            date: Date().addingTimeInterval(-daysAgo * 86400)
        )
    }
}
