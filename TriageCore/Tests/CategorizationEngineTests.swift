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

    func testNewsletterSubjectSuggestsCategoryButNotAutoAction() async throws {
        // A literal "weekly digest" is a useful hint, but it is still an ENGLISH keyword
        // and this mailbox is substantially Dutch — so it names the category without
        // authorising action on it. The sender triage screen is where bulk approval
        // belongs, rather than a keyword the mailbox may never contain.
        let email = makeEmail(
            senderEmail: "editor@somesite.com",
            subject: "Weekly digest: what happened",
            hasListUnsubscribe: true
        )
        let results = try await engine.categorize(emails: [email])

        XCTAssertEqual(results[0].category, .newsletter)
        XCTAssertEqual(results[0].safetyTier, .review)
    }

    func testDutchUtilityBillIsNotTreatedAsDisposableNewsletter() async throws {
        // Real regression: "Jaarafrekening van waterbedrijf Aquanet" (an annual water
        // bill) from noreply@mail.waterbedrijf.example was classified newsletter/.safe at 0.85.
        // Every English subject pattern misses it, the sender is unlisted, and the
        // `mail.` subdomain is only a generic transport signal — so the unsubscribe
        // fallback decided it, confidently and wrongly.
        let email = makeEmail(
            senderEmail: "noreply@mail.waterbedrijf.example",
            subject: "Jaarafrekening van waterbedrijf Aquanet",
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
        // NOT .safe any more, and this is the water-bill lesson generalised: `noreply@`
        // proves nobody reads replies, not that the content is disposable. The water
        // bill that started this was noreply@mail.waterbedrijf.example.
        XCTAssertEqual(results[0].safetyTier, .review)
        XCTAssertEqual(results[0].evidence, .weak)
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

        // The token still matches — that is what this test is about — but matching it no
        // longer authorises auto-action, because an unattended mailbox says nothing about
        // whether the content matters.
        XCTAssertEqual(results[0].category, .notification)
        XCTAssertEqual(results[0].safetyTier, .review)
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

// MARK: - The mail provider's own opinion

/// Gmail labels every message with exactly one `CATEGORY_*`, in any language, before this
/// app looks at it. These tests pin how that second opinion is used — as a veto when it
/// contradicts us about disposability, as corroboration when it agrees, and never as a
/// licence to delete more than the rules found on their own.
final class ProviderCategorySignalTests: XCTestCase {
    private var engine: RuleBasedEngine!

    override func setUp() {
        super.setUp()
        engine = RuleBasedEngine()
    }

    private func makeEmail(
        senderEmail: String,
        subject: String,
        labels: [String],
        hasListUnsubscribe: Bool = false
    ) -> EmailMetadata {
        var email = EmailMetadata(
            accountId: 1,
            messageId: UUID().uuidString,
            threadId: "t",
            sender: "Sender <\(senderEmail)>",
            senderEmail: senderEmail,
            subject: subject,
            date: Date(),
            hasListUnsubscribe: hasListUnsubscribe
        )
        email.labels = labels
        return email
    }

    func testUpdatesLabelVetoesAutoAction() async throws {
        // The real case in miniature: the rules say promotional, Gmail says Updates —
        // the bucket bills and confirmations land in. Measured on a live mailbox, 76 of
        // the 122 emails the rules called promotional were labelled Updates by Gmail.
        let email = makeEmail(
            senderEmail: "x@deals.someshop.com",
            subject: "Bekijk onze aanbiedingen",
            labels: ["INBOX", "UNREAD", "CATEGORY_UPDATES"],
            hasListUnsubscribe: true
        )
        let results = try await engine.categorize(emails: [email])

        XCTAssertEqual(
            results[0].safetyTier, .review,
            "a disagreement about disposability must not resolve itself by guessing"
        )
        XCTAssertEqual(results[0].evidence, .weak)
        XCTAssertTrue(results[0].reason.contains("Updates"))
    }

    func testPromotionsLabelCorroboratesAutoAction() async throws {
        // The other direction matters just as much: independent agreement restores the
        // cleanup power that requiring strong evidence would otherwise have cost.
        let email = makeEmail(
            senderEmail: "x@deals.someshop.com",
            subject: "Weekend sale",
            labels: ["INBOX", "CATEGORY_PROMOTIONS"],
            hasListUnsubscribe: true
        )
        let results = try await engine.categorize(emails: [email])

        XCTAssertEqual(results[0].safetyTier, .safe)
        XCTAssertEqual(results[0].evidence, .strong)
        XCTAssertGreaterThanOrEqual(results[0].confidence, 0.9)
    }

    func testLabelNeverMakesMailMoreDeletable() async throws {
        // A promotions label must not override a transactional finding. The provider
        // corroborates a conclusion the rules already reached; it is not a licence.
        let email = makeEmail(
            senderEmail: "noreply@chase.com",
            subject: "Your statement is ready",
            labels: ["INBOX", "CATEGORY_PROMOTIONS"]
        )
        let results = try await engine.categorize(emails: [email])

        XCTAssertEqual(results[0].category, .transactional)
        XCTAssertNotEqual(results[0].safetyTier, .safe)
    }

    func testLabelDoesNotOverrideAKnownContact() async throws {
        let contactEngine = RuleBasedEngine(knownContacts: ["friend@example.com"])
        let email = makeEmail(
            senderEmail: "friend@example.com",
            subject: "Sale on now",
            labels: ["CATEGORY_PROMOTIONS"]
        )
        let results = try await contactEngine.categorize(emails: [email])

        XCTAssertEqual(results[0].safetyTier, .protected_)
    }

    func testCorroborationLiftsAProvisionalReviewToActionable() async throws {
        // Regression. Corroboration used to PRESERVE the rules' tier, which was `.review`
        // only because their own evidence was weak — so agreed-upon marketing was neither
        // sent to the model nor actionable. On the live mailbox that was 52 emails and the
        // reason the app could clean nothing.
        let email = makeEmail(
            senderEmail: "hello@unrecognised.example",
            subject: "Bekijk onze nieuwe collectie",
            labels: ["INBOX", "CATEGORY_PROMOTIONS"],
            hasListUnsubscribe: true
        )
        let results = try await engine.categorize(emails: [email])

        XCTAssertEqual(
            results[0].safetyTier, .safe,
            "two independent classifiers agreeing is the evidence, not a relabelling"
        )
        XCTAssertEqual(results[0].evidence, .strong)
    }

    func testCorroborationStillCannotOverrideATransactionalFinding() async throws {
        // The lift must not become a general-purpose escalation: it applies only where the
        // rules independently concluded the mail was disposable.
        let email = makeEmail(
            senderEmail: "noreply@chase.com",
            subject: "Your statement is ready",
            labels: ["INBOX", "CATEGORY_PROMOTIONS"]
        )
        let results = try await engine.categorize(emails: [email])

        XCTAssertNotEqual(results[0].safetyTier, .safe)
    }

    func testVetoAppliesToAnyAutoActionableCategoryNotJustPromotions() async throws {
        // Regression from the live mailbox: a `social` domain match reached the actionable
        // tier without consulting the provider, because the veto keyed on a category list
        // that did not include social. Found as a YouTube Terms of Service notice Gmail had
        // filed under Updates.
        let email = makeEmail(
            senderEmail: "no-reply@youtube.com",
            subject: "Annual reminder about YouTube's Terms of Service",
            labels: ["INBOX", "CATEGORY_UPDATES"]
        )
        let results = try await engine.categorize(emails: [email])

        XCTAssertEqual(results[0].safetyTier, .review)
        XCTAssertTrue(results[0].reason.contains("Updates"))
    }

    func testSecurityAlertFromASocialPlatformIsNotAutoActionable() async throws {
        // The case the veto actually exists for, and the reason the YouTube finding mattered
        // despite being harmless itself: the same code path carries account-security mail.
        let email = makeEmail(
            senderEmail: "security@facebookmail.com",
            subject: "New login to your account from an unrecognised device",
            labels: ["INBOX", "CATEGORY_UPDATES"]
        )
        let results = try await engine.categorize(emails: [email])

        XCTAssertNotEqual(results[0].safetyTier, .safe)
    }

    func testSocialMailTheProviderAlsoCallsSocialStaysActionable() async throws {
        // The veto must not swallow the ordinary case it was never about.
        let email = makeEmail(
            senderEmail: "no-reply@youtube.com",
            subject: "Someone commented on your video",
            labels: ["INBOX", "CATEGORY_SOCIAL"]
        )
        let results = try await engine.categorize(emails: [email])

        XCTAssertEqual(results[0].safetyTier, .safe)
    }

    func testMailWithNoProviderLabelIsUnaffected() async throws {
        let email = makeEmail(
            senderEmail: "x@deals.someshop.com",
            subject: "Weekend sale",
            labels: ["INBOX", "UNREAD"]
        )
        let results = try await engine.categorize(emails: [email])

        XCTAssertEqual(results[0].category, .promotion)
        XCTAssertFalse(results[0].reason.contains("Gmail"))
    }
}
