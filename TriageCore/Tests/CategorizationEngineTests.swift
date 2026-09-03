import XCTest
@testable import TriageCore

final class RuleBasedEngineTests: XCTestCase {

    var engine: RuleBasedEngine!

    override func setUp() {
        engine = RuleBasedEngine(knownContacts: ["friend@gmail.com", "boss@company.com"])
    }

    // MARK: - Known Contacts (Rule 1 - Highest Priority)

    func testKnownContactIsProtected() async throws {
        let email = makeEmail(senderEmail: "friend@gmail.com", subject: "Hey!")
        let results = try await engine.categorize(emails: [email])

        XCTAssertEqual(results[0].category, .personal)
        XCTAssertEqual(results[0].safetyTier, .protected_)
        XCTAssertGreaterThan(results[0].confidence, 0.9)
    }

    func testKnownContactOverridesOtherRules() async throws {
        // Even if a known contact sends something that looks like a newsletter
        let email = makeEmail(
            senderEmail: "boss@company.com",
            subject: "Weekly digest",
            hasListUnsubscribe: true
        )
        let results = try await engine.categorize(emails: [email])

        // Contact detection wins over List-Unsubscribe
        XCTAssertEqual(results[0].category, .personal)
        XCTAssertEqual(results[0].safetyTier, .protected_)
    }

    // MARK: - List-Unsubscribe (Rule 2)

    func testListUnsubscribeIsNewsletter() async throws {
        let email = makeEmail(
            senderEmail: "updates@randomsite.com",
            subject: "Your weekly update",
            hasListUnsubscribe: true
        )
        let results = try await engine.categorize(emails: [email])

        XCTAssertEqual(results[0].category, .newsletter)
        XCTAssertEqual(results[0].safetyTier, .safe)
    }

    func testListUnsubscribeFromPromoIsPromo() async throws {
        let email = makeEmail(
            senderEmail: "deals@amazon.com",
            subject: "Today's deals",
            hasListUnsubscribe: true
        )
        let results = try await engine.categorize(emails: [email])

        XCTAssertEqual(results[0].category, .promotion)
        XCTAssertEqual(results[0].safetyTier, .safe)
    }

    // MARK: - Sender Pattern Matching (Rule 3)

    func testPromotionalDomain() async throws {
        let email = makeEmail(senderEmail: "news@walmart.com", subject: "New arrivals")
        let results = try await engine.categorize(emails: [email])

        XCTAssertEqual(results[0].category, .promotion)
    }

    func testNotificationDomain() async throws {
        let email = makeEmail(senderEmail: "noreply@github.com", subject: "New issue comment")
        let results = try await engine.categorize(emails: [email])

        // github.com is in notification domains
        XCTAssertEqual(results[0].category, .notification)
    }

    func testSocialPlatform() async throws {
        let email = makeEmail(senderEmail: "notification@facebookmail.com", subject: "You have a new friend request")
        let results = try await engine.categorize(emails: [email])

        XCTAssertEqual(results[0].category, .social)
    }

    func testTransactionalDomain() async throws {
        let email = makeEmail(senderEmail: "alerts@chase.com", subject: "Your statement is ready")
        let results = try await engine.categorize(emails: [email])

        XCTAssertEqual(results[0].category, .transactional)
        XCTAssertEqual(results[0].safetyTier, .review)  // Transactional = review, not auto-delete
    }

    func testMarketingPlatformDomain() async throws {
        let email = makeEmail(senderEmail: "bounce@sendgrid.net", subject: "Check out our latest")
        let results = try await engine.categorize(emails: [email])

        XCTAssertEqual(results[0].category, .promotion)
    }

    func testSubdomainPattern() async throws {
        let email = makeEmail(senderEmail: "offers@email.brand.com", subject: "New collection")
        let results = try await engine.categorize(emails: [email])

        XCTAssertEqual(results[0].category, .promotion)  // email.* subdomain = promotional
    }

    // MARK: - Subject Pattern Matching (Rule 4)

    func testPromotionalSubject() async throws {
        let email = makeEmail(senderEmail: "info@unknownshop.com", subject: "50% off everything today!")
        let results = try await engine.categorize(emails: [email])

        XCTAssertEqual(results[0].category, .promotion)
    }

    func testNotificationSubject() async throws {
        let email = makeEmail(senderEmail: "security@unknownsite.com", subject: "New sign-in to your account")
        let results = try await engine.categorize(emails: [email])

        XCTAssertEqual(results[0].category, .notification)
    }

    func testTransactionalSubject() async throws {
        let email = makeEmail(senderEmail: "billing@someservice.com", subject: "Your invoice for July")
        let results = try await engine.categorize(emails: [email])

        XCTAssertEqual(results[0].category, .transactional)
    }

    func testNewsletterSubject() async throws {
        let email = makeEmail(senderEmail: "editor@blog.com", subject: "Issue #42: This week in tech")
        let results = try await engine.categorize(emails: [email])

        XCTAssertEqual(results[0].category, .newsletter)
    }

    // MARK: - Automated Sender Detection (Rule 5)

    func testNoreplyIsNotification() async throws {
        let email = makeEmail(senderEmail: "noreply@unknownservice.com", subject: "Action needed")
        let results = try await engine.categorize(emails: [email])

        XCTAssertEqual(results[0].category, .notification)
        XCTAssertEqual(results[0].safetyTier, .safe)
    }

    func testNotificationsPrefix() async throws {
        let email = makeEmail(senderEmail: "notifications@someapp.com", subject: "Someone mentioned you")
        let results = try await engine.categorize(emails: [email])

        XCTAssertEqual(results[0].category, .notification)
    }

    // MARK: - Fallback (Unknown)

    func testUnknownSenderIsReview() async throws {
        let email = makeEmail(senderEmail: "randomuser123@customdomain.org", subject: "Hello there")
        let results = try await engine.categorize(emails: [email])

        XCTAssertEqual(results[0].category, .unknown)
        XCTAssertEqual(results[0].safetyTier, .review)
        XCTAssertLessThan(results[0].confidence, 0.5)
    }

    // MARK: - Batch Processing

    func testBatchCategorizationPerformance() async throws {
        let emails = (0..<1000).map { i in
            makeEmail(
                messageId: "msg_\(i)",
                senderEmail: "sender\(i % 10)@domain\(i % 5).com",
                subject: "Subject \(i)",
                hasListUnsubscribe: i % 3 == 0
            )
        }

        let start = Date()
        let results = try await engine.categorize(emails: emails)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(results.count, 1000)
        XCTAssertLessThan(elapsed, 1.0, "1000 emails should categorize in under 1 second")
    }

    // MARK: - Edge Cases

    func testAmazonMultiCategory() async throws {
        // Amazon sends both promotions and transactional emails
        // From the same domain — our rule engine will classify based on domain
        let promo = makeEmail(senderEmail: "store@amazon.com", subject: "Deal of the day")
        let receipt = makeEmail(senderEmail: "auto-confirm@amazon.com", subject: "Your order receipt")

        let results = try await engine.categorize(emails: [promo, receipt])

        // Both hit the promotional domain rule since amazon.com is in promotional set
        // This is a known limitation — AI engine would handle this better
        XCTAssertEqual(results[0].category, .promotion)
        XCTAssertEqual(results[1].category, .promotion)
    }

    // MARK: - Helpers

    private func makeEmail(
        messageId: String = "test_msg",
        senderEmail: String,
        subject: String,
        hasListUnsubscribe: Bool = false
    ) -> EmailMetadata {
        EmailMetadata(
            accountId: 1,
            messageId: messageId,
            sender: senderEmail.components(separatedBy: "@").first ?? "Unknown",
            senderEmail: senderEmail,
            subject: subject,
            date: Date(),
            hasListUnsubscribe: hasListUnsubscribe,
            isUnread: true
        )
    }
}

// MARK: - Sender Pattern Database Tests

final class SenderPatternDatabaseTests: XCTestCase {

    let patterns = SenderPatternDatabase.default

    func testPromotionalDomains() {
        XCTAssertTrue(patterns.isPromotionalDomain("amazon.com"))
        XCTAssertTrue(patterns.isPromotionalDomain("walmart.com"))
        XCTAssertFalse(patterns.isPromotionalDomain("mycompany.com"))
    }

    func testPromotionalSubdomains() {
        XCTAssertTrue(patterns.isPromotionalDomain("email.brand.com"))
        XCTAssertTrue(patterns.isPromotionalDomain("promo.shop.com"))
        XCTAssertTrue(patterns.isPromotionalDomain("offers.retailer.com"))
        XCTAssertFalse(patterns.isPromotionalDomain("api.brand.com"))
    }

    func testMarketingPlatforms() {
        XCTAssertTrue(patterns.isPromotionalDomain("sendgrid.net"))
        XCTAssertTrue(patterns.isPromotionalDomain("mailchimp.com"))
        XCTAssertTrue(patterns.isPromotionalDomain("hubspotmail.net"))
    }

    func testSocialPlatforms() {
        XCTAssertTrue(patterns.isSocialPlatform(domain: "facebook.com"))
        XCTAssertTrue(patterns.isSocialPlatform(domain: "facebookmail.com"))
        XCTAssertTrue(patterns.isSocialPlatform(domain: "linkedin.com"))
        XCTAssertTrue(patterns.isSocialPlatform(domain: "mail.instagram.com"))
        XCTAssertFalse(patterns.isSocialPlatform(domain: "mysite.com"))
    }

    func testNotificationDomains() {
        XCTAssertTrue(patterns.isNotificationSender(email: "noreply@github.com", domain: "github.com"))
        XCTAssertTrue(patterns.isNotificationSender(email: "alerts@sentry.io", domain: "sentry.io"))
        XCTAssertTrue(patterns.isNotificationSender(email: "bot@notify.service.com", domain: "notify.service.com"))
    }

    func testTransactionalDomains() {
        XCTAssertTrue(patterns.isTransactionalDomain("chase.com"))
        XCTAssertTrue(patterns.isTransactionalDomain("paypal.com"))
        XCTAssertFalse(patterns.isTransactionalDomain("randomshop.com"))
    }
}
