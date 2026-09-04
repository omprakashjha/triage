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

    func testListUnsubscribeAloneIsNotAutoActionable() async throws {
        // An unsubscribe header proves the mail is BULK, not that it is disposable.
        // From an unrecognised sender with no other signal, that must not be
        // auto-actionable — and the low confidence is what sends the sender to the AI.
        let email = makeEmail(
            senderEmail: "updates@randomsite.com",
            subject: "Your weekly update",
            hasListUnsubscribe: true
        )
        let results = try await engine.categorize(emails: [email])

        XCTAssertEqual(results[0].category, .newsletter)
        XCTAssertEqual(results[0].safetyTier, .review)
        XCTAssertLessThan(results[0].confidence, 0.7, "must fall below the AI ambiguity threshold")
    }

    func testGenuineNewsletterSubjectStaysAutoActionable() async throws {
        // Positive evidence keeps the cleanup power.
        let email = makeEmail(
            senderEmail: "editor@somesite.com",
            subject: "Weekly digest: what happened",
            hasListUnsubscribe: true
        )
        let results = try await engine.categorize(emails: [email])

        XCTAssertEqual(results[0].category, .newsletter)
        XCTAssertEqual(results[0].safetyTier, .safe)
    }

    func testDutchUtilityBillIsNotTreatedAsDisposableNewsletter() async throws {
        // Real regression: "Jaarafrekening van waterbedrijf Vitens" (an annual water
        // bill) from noreply@mail.vitens.nl was classified newsletter/.safe at 0.85.
        // Every English subject pattern misses it, the sender is unlisted, and the
        // `mail.` subdomain is only a generic transport signal — so the unsubscribe
        // fallback decided it, confidently and wrongly.
        let email = makeEmail(
            senderEmail: "noreply@mail.vitens.nl",
            subject: "Jaarafrekening van waterbedrijf Vitens",
            hasListUnsubscribe: true
        )
        let results = try await engine.categorize(emails: [email])

        XCTAssertNotEqual(results[0].safetyTier, .safe, "a utility bill must not be auto-actionable")
        XCTAssertLessThan(
            results[0].confidence, 0.7,
            "must be low enough that the AI is asked, since the rules cannot read Dutch"
        )
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
        // Amazon sends both promotions and transactional mail from one domain, so the
        // domain alone cannot decide. The subject breaks the tie.
        let promo = makeEmail(senderEmail: "store@amazon.com", subject: "Deal of the day")
        let receipt = makeEmail(senderEmail: "auto-confirm@amazon.com", subject: "Your order receipt")

        let results = try await engine.categorize(emails: [promo, receipt])

        XCTAssertEqual(results[0].category, .promotion)
        XCTAssertEqual(results[0].safetyTier, .safe)

        // Previously this also came back as .promotion / .safe and was auto-deleted
        // after 30 days by the default rules.
        XCTAssertEqual(results[1].category, .transactional)
        XCTAssertEqual(results[1].safetyTier, .review)
    }

    func testMixedSenderWithAmbiguousSubjectNeedsReview() async throws {
        let email = makeEmail(senderEmail: "no-reply@apple.com", subject: "Your Apple ID was used to sign in")
        let results = try await engine.categorize(emails: [email])

        // Ambiguous subject from a mixed sender must never be auto-actionable.
        XCTAssertNotEqual(results[0].safetyTier, .safe)
    }

    // MARK: - Regression: generic transport subdomains must not auto-delete

    func testBankOnGenericMailSubdomainIsNotAutoDeletable() async throws {
        // `mail.` is a generic bulk-transport subdomain used by banks as much as retailers.
        // This previously matched the promotional subdomain heuristic BEFORE the
        // transactional check and became .promotion/.safe -> deleted after 30 days.
        let email = makeEmail(senderEmail: "alerts@mail.chase.com", subject: "Your statement is ready")
        let results = try await engine.categorize(emails: [email])

        XCTAssertEqual(results[0].category, .transactional)
        XCTAssertEqual(results[0].safetyTier, .review)
    }

    func testUnknownSenderOnGenericMailSubdomainIsReviewNotSafe() async throws {
        // An unlisted domain behind `mail.` is only weak evidence of marketing.
        let email = makeEmail(senderEmail: "hello@mail.mylocalcreditunion.com", subject: "Notice about your account")
        let results = try await engine.categorize(emails: [email])

        XCTAssertEqual(results[0].safetyTier, .review, "generic subdomain alone must not be auto-actionable")
    }

    func testDiscriminatingPromoSubdomainStaysSafe() async throws {
        // `deals.` genuinely signals marketing, so auto-action is still appropriate.
        let email = makeEmail(senderEmail: "x@deals.someshop.com", subject: "New arrivals")
        let results = try await engine.categorize(emails: [email])

        XCTAssertEqual(results[0].category, .promotion)
        XCTAssertEqual(results[0].safetyTier, .safe)
    }

    func testReceiptWithListUnsubscribeIsNotAutoDeletable() async throws {
        // Transactional mail increasingly carries one-click unsubscribe headers.
        let email = makeEmail(
            senderEmail: "billing@someservice.io",
            subject: "Your invoice for July",
            hasListUnsubscribe: true
        )
        let results = try await engine.categorize(emails: [email])

        XCTAssertEqual(results[0].category, .transactional)
        XCTAssertEqual(results[0].safetyTier, .review)
    }

    // MARK: - Regression: automated-sender false positives

    func testInfoAddressIsNotAutoDeletable() async throws {
        // `info@` is how a great many small businesses and clinics send real mail.
        let email = makeEmail(senderEmail: "info@thelocalgarage.co.uk", subject: "About your booking on Tuesday")
        let results = try await engine.categorize(emails: [email])

        XCTAssertNotEqual(results[0].safetyTier, .safe, "ambiguous local part must not be auto-actionable")
    }

    func testSurnameStartingWithAutomatedTokenIsNotAutomated() async throws {
        // "newsome" starts with "news" but is a surname — prefix matching got this wrong.
        let email = makeEmail(senderEmail: "jnewsome@somefirm.com", subject: "Following up on our call")
        let results = try await engine.categorize(emails: [email])

        XCTAssertEqual(results[0].category, .unknown)
        XCTAssertEqual(results[0].safetyTier, .review)
    }

    func testAutomatedTokenWithSeparatorStillMatches() async throws {
        let email = makeEmail(senderEmail: "no-reply@someservice.com", subject: "Scheduled maintenance")
        let results = try await engine.categorize(emails: [email])

        XCTAssertEqual(results[0].category, .notification)
        XCTAssertEqual(results[0].safetyTier, .safe)
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
