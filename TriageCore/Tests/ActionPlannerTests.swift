import XCTest
@testable import TriageCore

final class ActionPlannerTests: XCTestCase {

    // MARK: - Plan Generation

    func testDefaultPlanArchivesNewsletters() {
        let planner = ActionPlanner()
        let emails = makeEmails(count: 50, category: .newsletter, daysOld: 15)

        let plan = planner.generatePlan(emails: emails, accountId: 1)

        let newsletterItem = plan.items.first { $0.category == .newsletter }
        XCTAssertNotNil(newsletterItem)
        XCTAssertEqual(newsletterItem?.action, .archived)
        XCTAssertEqual(newsletterItem?.emailCount, 50)  // No age filter for newsletters by default
        XCTAssertTrue(newsletterItem?.isApproved ?? false)
    }

    func testDefaultPlanDeletesOldPromotions() {
        let planner = ActionPlanner()
        let oldPromos = makeEmails(count: 30, category: .promotion, daysOld: 45)
        let newPromos = makeEmails(count: 20, category: .promotion, daysOld: 5, startId: 30)

        let plan = planner.generatePlan(emails: oldPromos + newPromos, accountId: 1)

        let promoItem = plan.items.first { $0.category == .promotion }
        XCTAssertNotNil(promoItem)
        XCTAssertEqual(promoItem?.action, .deleted)
        XCTAssertEqual(promoItem?.emailCount, 30)  // Only the ones older than 30 days
    }

    func testDefaultPlanDeletesOldNotifications() {
        let planner = ActionPlanner()
        let emails = makeEmails(count: 100, category: .notification, daysOld: 60)

        let plan = planner.generatePlan(emails: emails, accountId: 1)

        let notifItem = plan.items.first { $0.category == .notification }
        XCTAssertEqual(notifItem?.action, .deleted)
        XCTAssertEqual(notifItem?.emailCount, 100)
    }

    func testPersonalEmailsNeverInPlan() {
        let planner = ActionPlanner()
        let emails = makeEmails(count: 50, category: .personal, daysOld: 365)

        let plan = planner.generatePlan(emails: emails, accountId: 1)

        let personalItem = plan.items.first { $0.category == .personal }
        XCTAssertNil(personalItem)  // Skipped categories don't appear
    }

    func testProtectedEmailsExcludedFromPlan() {
        let planner = ActionPlanner()
        var emails = makeEmails(count: 10, category: .newsletter, daysOld: 30)
        // Mark some as protected
        for i in 0..<5 {
            emails[i] = EmailMetadata(
                accountId: 1,
                messageId: emails[i].messageId,
                sender: emails[i].sender,
                senderEmail: emails[i].senderEmail,
                subject: emails[i].subject,
                date: emails[i].date,
                category: .newsletter,
                safetyTier: .protected_
            )
        }

        let plan = planner.generatePlan(emails: emails, accountId: 1)

        let item = plan.items.first { $0.category == .newsletter }
        XCTAssertEqual(item?.emailCount, 5)  // Only unprotected ones
    }

    func testUnknownEmailsNotAutoApproved() {
        let planner = ActionPlanner(rules: ActionRules(
            newsletterAction: .archived, newsletterMaxAgeDays: nil,
            promotionAction: .deleted, promotionMaxAgeDays: 30,
            notificationAction: .deleted, notificationMaxAgeDays: 30,
            socialAction: .archived, socialMaxAgeDays: 60,
            transactionalAction: .archived, transactionalMaxAgeDays: 90,
            personalAction: .skipped,
            unknownAction: .archived  // Even if rule says archive...
        ))
        let emails = makeEmails(count: 20, category: .unknown, daysOld: 10)

        let plan = planner.generatePlan(emails: emails, accountId: 1)

        let unknownItem = plan.items.first { $0.category == .unknown }
        XCTAssertFalse(unknownItem?.isApproved ?? true)  // Not auto-approved
    }

    // MARK: - Summary Calculation

    func testPlanSummaryCalculation() {
        let planner = ActionPlanner()
        let newsletters = makeEmails(count: 100, category: .newsletter, daysOld: 10)
        let promos = makeEmails(count: 50, category: .promotion, daysOld: 45, startId: 100)
        let personal = makeEmails(count: 30, category: .personal, daysOld: 10, startId: 150)

        let plan = planner.generatePlan(emails: newsletters + promos + personal, accountId: 1)

        XCTAssertEqual(plan.summary.totalEmails, 180)
        XCTAssertEqual(plan.summary.toArchive, 100)  // Newsletters
        XCTAssertEqual(plan.summary.toDelete, 50)    // Old promos
    }

    // MARK: - Sender Breakdown

    func testSenderBreakdown() {
        let planner = ActionPlanner()
        var emails: [EmailMetadata] = []
        // 20 from sender A, 10 from sender B
        for i in 0..<20 {
            emails.append(EmailMetadata(
                accountId: 1, messageId: "msg_\(i)",
                sender: "Sender A", senderEmail: "a@newsletters.com",
                subject: "Update \(i)", date: Date().addingTimeInterval(-86400 * 10),
                category: .newsletter, safetyTier: .safe
            ))
        }
        for i in 20..<30 {
            emails.append(EmailMetadata(
                accountId: 1, messageId: "msg_\(i)",
                sender: "Sender B", senderEmail: "b@newsletters.com",
                subject: "Digest \(i)", date: Date().addingTimeInterval(-86400 * 10),
                category: .newsletter, safetyTier: .safe
            ))
        }

        let plan = planner.generatePlan(emails: emails, accountId: 1)
        let item = plan.items.first { $0.category == .newsletter }!
        let breakdown = item.senderBreakdown

        XCTAssertEqual(breakdown.count, 2)
        XCTAssertEqual(breakdown[0].count, 20)  // Sender A (most emails first)
        XCTAssertEqual(breakdown[1].count, 10)  // Sender B
    }

    // MARK: - Aggressive Rules

    func testAggressiveRulesDeleteMoreAggressively() {
        let planner = ActionPlanner(rules: .aggressive)
        let newsletters = makeEmails(count: 50, category: .newsletter, daysOld: 10)

        let plan = planner.generatePlan(emails: newsletters, accountId: 1)

        let item = plan.items.first { $0.category == .newsletter }
        XCTAssertEqual(item?.action, .deleted)  // Aggressive deletes newsletters
        XCTAssertEqual(item?.emailCount, 50)    // >7 days old
    }

    // MARK: - Action Rules

    func testCustomRules() {
        let customRules = ActionRules(
            newsletterAction: .deleted,
            newsletterMaxAgeDays: 14,
            promotionAction: .deleted,
            promotionMaxAgeDays: 7,
            notificationAction: .archived,
            notificationMaxAgeDays: nil,
            socialAction: .skipped,
            socialMaxAgeDays: nil,
            transactionalAction: .skipped,
            transactionalMaxAgeDays: nil,
            personalAction: .skipped,
            unknownAction: .skipped
        )
        let planner = ActionPlanner(rules: customRules)
        let newsletters = makeEmails(count: 40, category: .newsletter, daysOld: 20)
        let social = makeEmails(count: 30, category: .social, daysOld: 90, startId: 40)

        let plan = planner.generatePlan(emails: newsletters + social, accountId: 1)

        let nlItem = plan.items.first { $0.category == .newsletter }
        XCTAssertEqual(nlItem?.action, .deleted)
        XCTAssertEqual(nlItem?.emailCount, 40)

        let socialItem = plan.items.first { $0.category == .social }
        XCTAssertNil(socialItem)  // Skipped
    }

    // MARK: - Execution (Database Integration)

    func testMarkEmailsActioned() async throws {
        let database = try AppDatabase.inMemory()
        var account = EmailAccount(email: "test@gmail.com", provider: .gmail)
        try await database.saveAccount(&account)
        let accountId = account.id!

        let emails = [
            EmailMetadata(accountId: accountId, messageId: "msg_1", sender: "A", senderEmail: "a@x.com", subject: "S", date: Date()),
            EmailMetadata(accountId: accountId, messageId: "msg_2", sender: "B", senderEmail: "b@x.com", subject: "S", date: Date()),
        ]
        try await database.batchUpsertEmails(emails)

        try await database.markEmailsActioned(messageIds: ["msg_1", "msg_2"], accountId: accountId, action: .archived)

        let fetched = try await database.fetchEmails(accountId: accountId)
        XCTAssertEqual(fetched[0].actionTaken, .archived)
        XCTAssertEqual(fetched[1].actionTaken, .archived)
    }

    func testUndoClearsAction() async throws {
        let database = try AppDatabase.inMemory()
        var account = EmailAccount(email: "test@gmail.com", provider: .gmail)
        try await database.saveAccount(&account)
        let accountId = account.id!

        let emails = [
            EmailMetadata(accountId: accountId, messageId: "msg_1", sender: "A", senderEmail: "a@x.com", subject: "S", date: Date()),
        ]
        try await database.batchUpsertEmails(emails)

        // Action
        try await database.markEmailsActioned(messageIds: ["msg_1"], accountId: accountId, action: .deleted)

        // Undo
        try await database.markEmailsActioned(messageIds: ["msg_1"], accountId: accountId, action: nil)

        let fetched = try await database.fetchEmails(accountId: accountId)
        XCTAssertNil(fetched[0].actionTaken)
    }

    // MARK: - Helpers

    private func makeEmails(count: Int, category: EmailCategory, daysOld: Int, startId: Int = 0) -> [EmailMetadata] {
        (0..<count).map { i in
            EmailMetadata(
                accountId: 1,
                messageId: "msg_\(startId + i)",
                sender: "Sender \(i)",
                senderEmail: "sender\(i)@example.com",
                subject: "Subject \(i)",
                date: Date().addingTimeInterval(-Double(daysOld) * 86400),
                category: category,
                safetyTier: category == .personal ? .protected_ : .safe
            )
        }
    }
}
