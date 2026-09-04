import XCTest
@testable import TriageBedrock
@testable import TriageCore

/// Live tests against real Bedrock.
///
/// Every test here SKIPS unless `TRIAGE_LIVE_BEDROCK=1`, so a normal `swift test`
/// makes no network calls, needs no credentials and spends nothing. Run them
/// deliberately after `aws sso login`:
///
///     TRIAGE_LIVE_BEDROCK=1 swift test --disable-sandbox --filter TriageBedrockLiveTests
///
/// These exist because the parts that can only fail against the real service are
/// exactly the parts a mock cannot cover: whether the model accepts the schema,
/// whether forced tool use actually returns a tool block, and whether the
/// JSONValue <-> Smithy.Document bridge round-trips.
final class TriageBedrockLiveTests: XCTestCase {

    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["TRIAGE_LIVE_BEDROCK"] == "1"
    }

    private func skipUnlessEnabled() throws {
        try XCTSkipUnless(
            isEnabled,
            "Set TRIAGE_LIVE_BEDROCK=1 (and run aws sso login) to exercise real Bedrock."
        )
    }

    /// Model id override, so this can be pointed at whatever the account actually has.
    private var modelId: String {
        ProcessInfo.processInfo.environment["TRIAGE_LIVE_MODEL"]
            ?? BedrockLLMTransport.defaultModelId
    }

    // MARK: - The three cases rules cannot settle

    func testClassifiesHardSendersSafely() async throws {
        try skipUnlessEnabled()

        let transport = BedrockLLMTransport(modelId: modelId)

        let senders = [
            // A mixed sender: one domain, both marketing and order records.
            SenderClassificationRequest(
                senderEmail: "auto-confirm@amazon.com",
                displayName: "Amazon.com",
                sampleSubjects: [
                    "Your order has shipped",
                    "Your Amazon.com order of \"USB-C cable\"",
                    "Delivered: your package",
                ],
                totalEmails: 47,
                hasUnsubscribe: false,
                averageIntervalDays: 6.2
            ),
            // The case the rule engine structurally cannot get right: info@ is a real
            // person at a small business.
            SenderClassificationRequest(
                senderEmail: "info@thelocalgarage.co.uk",
                displayName: "The Local Garage",
                sampleSubjects: [
                    "About your booking on Tuesday",
                    "Re: MOT reminder for your car",
                    "Quote for the brake work",
                ],
                totalEmails: 4,
                hasUnsubscribe: false,
                averageIntervalDays: 90
            ),
            // A bank behind a generic mail. subdomain, WITH an unsubscribe header.
            SenderClassificationRequest(
                senderEmail: "alerts@mail.chase.com",
                displayName: "Chase",
                sampleSubjects: [
                    "Your statement is ready",
                    "Your account alert",
                    "Payment received",
                ],
                totalEmails: 22,
                hasUnsubscribe: true,
                averageIntervalDays: 14
            ),
        ]

        let verdicts = try await transport.classify(senders: senders)

        XCTAssertEqual(verdicts.count, 3, "forced tool use should return one verdict per sender")

        let byAddress = Dictionary(
            verdicts.map { ($0.senderEmail, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // The judgements that matter are the SAFETY ones, not the category label.
        for (address, verdict) in byAddress {
            XCTAssertTrue(
                verdict.mustKeep,
                "\(address) holds records or correspondence and must not be marked disposable"
            )
            XCTAssertNotEqual(
                verdict.impliedTier, .safe,
                "\(address) must not land in the auto-actionable tier"
            )
            XCTAssertGreaterThan(verdict.confidence, 0)
            XCTAssertFalse(verdict.reason.isEmpty, "the user needs a reason to read")
        }

        // The garage is the one a model should recognise as a person.
        if let garage = byAddress["info@thelocalgarage.co.uk"] {
            XCTAssertTrue(
                garage.isRealPerson,
                "a small business writing about your booking is a person, not a system"
            )
            XCTAssertEqual(garage.impliedTier, .protected_)
        }
    }

    /// A promotional sender SHOULD come back disposable — otherwise the model is simply
    /// answering mustKeep=true to everything and the safety signal carries no information.
    func testRecognisesGenuinelyDisposableMail() async throws {
        try skipUnlessEnabled()

        let transport = BedrockLLMTransport(modelId: modelId)
        let verdicts = try await transport.classify(senders: [
            SenderClassificationRequest(
                senderEmail: "deals@flashsale-outlet.example",
                displayName: "Flash Sale Outlet",
                sampleSubjects: [
                    "50% OFF EVERYTHING - 24 HOURS ONLY",
                    "Last chance: your cart is expiring",
                    "FLASH SALE: doorbusters inside",
                    "Extra 20% off clearance",
                ],
                totalEmails: 210,
                hasUnsubscribe: true,
                averageIntervalDays: 1.1
            )
        ])

        let verdict = try XCTUnwrap(verdicts.first)
        XCTAssertEqual(verdict.category, .promotion)
        XCTAssertFalse(verdict.mustKeep, "pure marketing must be recognised as disposable")
        XCTAssertEqual(verdict.impliedTier, .safe)
    }

    /// Exercises the full engine — cascade, cache and the narrowing-only merge — against
    /// the real service, which the mock transport cannot cover.
    func testEngineEndToEndWithRealTransport() async throws {
        try skipUnlessEnabled()

        let db = try AppDatabase.inMemory()
        var account = EmailAccount(email: "me@example.com", provider: .gmail, createdAt: Date())
        try await db.saveAccount(&account)
        let accountId = account.id!

        let transport = BedrockLLMTransport(modelId: modelId)
        let engine = AICategorizationEngine(
            rules: RuleBasedEngine(),
            transport: transport,
            cache: db,
            accountId: accountId
        )

        let email = EmailMetadata(
            accountId: accountId,
            messageId: "m1",
            sender: "The Local Garage",
            senderEmail: "info@thelocalgarage.co.uk",
            subject: "About your booking on Tuesday",
            date: Date()
        )

        let results = try await engine.categorize(emails: [email])
        let result = try XCTUnwrap(results.first)

        // Rules alone rate info@ as weak/notification; the model should raise it.
        XCTAssertNotEqual(result.safetyTier, .safe, "the merge must not leave this auto-deletable")
        XCTAssertTrue(result.reason.contains("AI:"), "the AI reason should reach the user")

        // And the verdict must have been cached, so a rescan costs nothing.
        let cached = try await db.cachedVerdictCount(
            accountId: accountId,
            modelId: transport.modelId,
            promptVersion: transport.promptVersion
        )
        XCTAssertEqual(cached, 1)
    }
}
