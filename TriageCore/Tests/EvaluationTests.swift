import XCTest
@testable import TriageCore

final class EvaluationTests: XCTestCase {

    private let old = Date().addingTimeInterval(-100 * 86400)

    private func email(
        _ id: String,
        sender: String,
        subject: String = "Subject",
        date: Date? = nil
    ) -> EmailMetadata {
        EmailMetadata(
            accountId: 1,
            messageId: id,
            sender: sender,
            senderEmail: sender,
            subject: subject,
            date: date ?? old
        )
    }

    private func result(
        _ id: String,
        _ category: EmailCategory,
        _ tier: SafetyTier,
        _ confidence: Double = 0.85
    ) -> CategorizationResult {
        CategorizationResult(
            messageId: id,
            category: category,
            safetyTier: tier,
            confidence: confidence,
            reason: "test"
        )
    }

    private func label(
        _ sender: String,
        _ category: EmailCategory,
        _ disposition: Disposition
    ) -> GoldenLabel {
        GoldenLabel(
            accountId: 1,
            senderEmail: sender,
            expectedCategory: category,
            disposition: disposition
        )
    }

    // MARK: - The headline metric

    func testDestructivePrecisionCountsMustKeepMailAsFailure() {
        // Both are old promotions in the safe tier, so default rules delete both.
        let emails = [
            email("a", sender: "promo@shop.com"),
            email("b", sender: "receipts@store.com", subject: "Your order receipt"),
        ]
        let results = [
            result("a", .promotion, .safe),
            result("b", .promotion, .safe),
        ]
        let labels = [
            label("promo@shop.com", .promotion, .disposable),
            label("receipts@store.com", .transactional, .mustKeep),
        ]

        let report = CategorizationEvaluator(rules: .default)
            .evaluate(emails: emails, results: results, labels: labels)

        XCTAssertEqual(report.evaluatedEmails, 2)
        XCTAssertEqual(report.destructiveTotal, 2)
        XCTAssertEqual(report.destructivePrecision, 0.5)
        XCTAssertEqual(report.destructiveFalsePositives.count, 1)
        XCTAssertEqual(report.destructiveFalsePositives[0].senderEmail, "receipts@store.com")
        XCTAssertFalse(report.isDestructivePathClean)
    }

    func testCleanDestructivePathWhenAllDeletionsAreDisposable() {
        let emails = [
            email("a", sender: "promo@shop.com"),
            email("b", sender: "deals@shop2.com"),
        ]
        let results = [
            result("a", .promotion, .safe),
            result("b", .promotion, .safe),
        ]
        let labels = [
            label("promo@shop.com", .promotion, .disposable),
            label("deals@shop2.com", .promotion, .disposable),
        ]

        let report = CategorizationEvaluator(rules: .default)
            .evaluate(emails: emails, results: results, labels: labels)

        XCTAssertEqual(report.destructivePrecision, 1.0)
        XCTAssertTrue(report.isDestructivePathClean)
        XCTAssertTrue(report.headline.contains("no must-keep mail"))
    }

    func testPrecisionIsNilWhenNothingWouldBeDeleted() {
        // Review-tier mail is not auto-approved, so the destructive path is empty.
        let emails = [email("a", sender: "bank@mail.chase.com")]
        let results = [result("a", .transactional, .review, 0.75)]
        let labels = [label("bank@mail.chase.com", .transactional, .mustKeep)]

        let report = CategorizationEvaluator(rules: .default)
            .evaluate(emails: emails, results: results, labels: labels)

        XCTAssertEqual(report.destructiveTotal, 0)
        XCTAssertNil(report.destructivePrecision)
        XCTAssertTrue(report.isDestructivePathClean, "nothing deleted means nothing wrongly deleted")
    }

    func testReviewTierProtectsMustKeepMailFromTheDestructivePath() {
        // This is the regression guard for the receipt-deletion bug: the same mail in
        // the safe tier WOULD be deleted, in the review tier it must not be.
        let emails = [email("a", sender: "receipts@store.com", subject: "Your invoice")]
        let labels = [label("receipts@store.com", .transactional, .mustKeep)]

        let asSafe = CategorizationEvaluator(rules: .default).evaluate(
            emails: emails,
            results: [result("a", .promotion, .safe)],
            labels: labels
        )
        XCTAssertEqual(asSafe.destructiveFalsePositives.count, 1)

        let asReview = CategorizationEvaluator(rules: .default).evaluate(
            emails: emails,
            results: [result("a", .promotion, .review)],
            labels: labels
        )
        XCTAssertTrue(asReview.isDestructivePathClean)
    }

    // MARK: - Scope

    func testOnlyLabelledSendersAreScored() {
        let emails = [
            email("a", sender: "labelled@shop.com"),
            email("b", sender: "unlabelled@shop.com"),
        ]
        let results = [
            result("a", .promotion, .safe),
            result("b", .promotion, .safe),
        ]
        let labels = [label("labelled@shop.com", .promotion, .disposable)]

        let report = CategorizationEvaluator(rules: .default)
            .evaluate(emails: emails, results: results, labels: labels)

        XCTAssertEqual(report.evaluatedEmails, 1, "unlabelled mail has no ground truth and cannot be scored")
    }

    func testEmptyLabelSetProducesAnHonestEmptyReport() {
        let report = CategorizationEvaluator(rules: .default)
            .evaluate(emails: [], results: [], labels: [])

        XCTAssertEqual(report.evaluatedEmails, 0)
        XCTAssertNil(report.destructivePrecision)
        XCTAssertNil(report.categoryAccuracy)
        XCTAssertTrue(report.headline.contains("No labelled senders"))
    }

    // MARK: - Secondary metrics

    func testCategoryAccuracy() {
        let emails = [
            email("a", sender: "a@x.com"),
            email("b", sender: "b@x.com"),
        ]
        let results = [
            result("a", .promotion, .safe),
            result("b", .promotion, .safe),
        ]
        let labels = [
            label("a@x.com", .promotion, .disposable),   // correct
            label("b@x.com", .newsletter, .disposable),  // wrong
        ]

        let report = CategorizationEvaluator(rules: .default)
            .evaluate(emails: emails, results: results, labels: labels)

        XCTAssertEqual(report.categoryAccuracy, 0.5)
    }

    func testPerCategoryPrecisionAndRecall() {
        let emails = [
            email("a", sender: "a@x.com"),
            email("b", sender: "b@x.com"),
            email("c", sender: "c@x.com"),
        ]
        // Two predicted promotion (one right), one predicted newsletter (wrong).
        let results = [
            result("a", .promotion, .safe),
            result("b", .promotion, .safe),
            result("c", .newsletter, .safe),
        ]
        let labels = [
            label("a@x.com", .promotion, .disposable),
            label("b@x.com", .newsletter, .disposable),
            label("c@x.com", .promotion, .disposable),
        ]

        let report = CategorizationEvaluator(rules: .default)
            .evaluate(emails: emails, results: results, labels: labels)

        let promotion = report.perCategory[.promotion]
        XCTAssertEqual(promotion?.predictedCount, 2)
        XCTAssertEqual(promotion?.actualCount, 2)
        XCTAssertEqual(promotion?.precision, 0.5)
        XCTAssertEqual(promotion?.recall, 0.5)
    }

    func testDisposableSweptFraction() {
        // Two disposable senders; only the old one falls inside the 30-day delete rule.
        let emails = [
            email("old", sender: "a@x.com"),
            email("recent", sender: "b@x.com", date: Date()),
        ]
        let results = [
            result("old", .promotion, .safe),
            result("recent", .promotion, .safe),
        ]
        let labels = [
            label("a@x.com", .promotion, .disposable),
            label("b@x.com", .promotion, .disposable),
        ]

        let report = CategorizationEvaluator(rules: .default)
            .evaluate(emails: emails, results: results, labels: labels)

        XCTAssertEqual(report.disposableSweptFraction, 0.5)
        XCTAssertEqual(report.destructivePrecision, 1.0, "recall being low must not dent precision")
    }

    // MARK: - Calibration

    func testCalibrationBucketsReportObservedAccuracy() {
        let emails = (0..<4).map { email("m\($0)", sender: "s\($0)@x.com") }
        // All stated at 0.9 confidence; half are actually right.
        let results = [
            result("m0", .promotion, .safe, 0.9),
            result("m1", .promotion, .safe, 0.9),
            result("m2", .promotion, .safe, 0.9),
            result("m3", .promotion, .safe, 0.9),
        ]
        let labels = [
            label("s0@x.com", .promotion, .disposable),
            label("s1@x.com", .promotion, .disposable),
            label("s2@x.com", .newsletter, .disposable),
            label("s3@x.com", .newsletter, .disposable),
        ]

        let report = CategorizationEvaluator(rules: .default)
            .evaluate(emails: emails, results: results, labels: labels)

        XCTAssertEqual(report.calibration.count, 1)
        let bucket = report.calibration[0]
        XCTAssertEqual(bucket.count, 4)
        XCTAssertEqual(bucket.observedAccuracy, 0.5)
        XCTAssertGreaterThan(bucket.overconfidenceGap, 0.1, "stated 85-100% but only 50% correct")
    }

    // MARK: - Persistence

    func testGoldenLabelUpsertAndExport() async throws {
        let db = try AppDatabase.inMemory()
        var account = EmailAccount(email: "me@example.com", provider: .gmail, createdAt: Date())
        try await db.saveAccount(&account)
        let accountId = account.id!

        try await db.saveGoldenLabel(
            GoldenLabel(accountId: accountId, senderEmail: "A@Shop.com",
                        expectedCategory: .promotion, disposition: .disposable)
        )
        // Re-labelling the same sender must replace, not duplicate.
        try await db.saveGoldenLabel(
            GoldenLabel(accountId: accountId, senderEmail: "a@shop.com",
                        expectedCategory: .transactional, disposition: .mustKeep)
        )

        let labels = try await db.fetchGoldenLabels(accountId: accountId)
        XCTAssertEqual(labels.count, 1)
        XCTAssertEqual(labels[0].senderEmail, "a@shop.com")
        XCTAssertEqual(labels[0].disposition, .mustKeep)

        let export = try await db.exportGoldenSet(accountId: accountId, accountEmail: "me@example.com")
        XCTAssertEqual(export.labels.count, 1)
        XCTAssertEqual(export.labels[0].disposition, "mustKeep")
    }

    func testEvaluateThroughDatabaseUsesLiveEngine() async throws {
        let db = try AppDatabase.inMemory()
        var account = EmailAccount(email: "me@example.com", provider: .gmail, createdAt: Date())
        try await db.saveAccount(&account)
        let accountId = account.id!

        try await db.batchUpsertEmails([
            EmailMetadata(
                accountId: accountId, messageId: "m1", sender: "S",
                senderEmail: "alerts@mail.chase.com",
                subject: "Your statement is ready", date: old
            )
        ])
        try await db.saveGoldenLabel(
            GoldenLabel(accountId: accountId, senderEmail: "alerts@mail.chase.com",
                        expectedCategory: .transactional, disposition: .mustKeep)
        )

        let report = try await db.evaluate(
            accountId: accountId,
            engine: RuleBasedEngine(),
            rules: .default
        )

        // The fixed precedence should keep this bank statement out of the delete path.
        XCTAssertEqual(report.evaluatedEmails, 1)
        XCTAssertTrue(
            report.isDestructivePathClean,
            "mail.chase.com must not reach the destructive path after the precedence fix"
        )
    }
}
