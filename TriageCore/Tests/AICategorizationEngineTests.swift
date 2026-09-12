import XCTest
@testable import TriageCore

/// A transport that returns scripted verdicts and records what it was asked.
private final class MockTransport: LLMTransport, @unchecked Sendable {
    let modelId: String
    let promptVersion: String
    private(set) var receivedBatches: [[SenderClassificationRequest]] = []
    /// What the engine passed through from the user's corrections, so the prompt-feedback
    /// path can be asserted rather than assumed.
    private(set) var receivedCorrections: [CorrectionExample] = []
    private let verdicts: [String: SenderVerdict]

    init(
        modelId: String = "mock-model",
        promptVersion: String = "sender.v1",
        verdicts: [String: SenderVerdict] = [:]
    ) {
        self.modelId = modelId
        self.promptVersion = promptVersion
        self.verdicts = verdicts
    }

    var callCount: Int { receivedBatches.count }
    var sendersAsked: [String] { receivedBatches.flatMap { $0.map(\.senderEmail) } }

    func classify(
        senders: [SenderClassificationRequest],
        corrections: [CorrectionExample]
    ) async throws -> [SenderVerdict] {
        receivedCorrections = corrections
        receivedBatches.append(senders)
        return senders.compactMap { verdicts[$0.senderEmail.lowercased()] }
    }
}

final class AICategorizationEngineTests: XCTestCase {

    private func email(_ id: String, sender: String, subject: String = "Subject") -> EmailMetadata {
        EmailMetadata(
            accountId: 1,
            messageId: id,
            sender: sender,
            senderEmail: sender,
            subject: subject,
            date: Date()
        )
    }

    private func verdict(
        _ sender: String,
        category: EmailCategory = .promotion,
        mustKeep: Bool = false,
        isRealPerson: Bool = false,
        confidence: Double = 0.9,
        isUnsure: Bool = false
    ) -> SenderVerdict {
        SenderVerdict(
            senderEmail: sender,
            category: category,
            mustKeep: mustKeep,
            isRealPerson: isRealPerson,
            confidence: confidence,
            reason: "mock reason",
            isUnsure: isUnsure
        )
    }

    // MARK: - The safety guarantee

    func testAIVerdictAloneCannotLoosenSafety() {
        // Rules were unsure. The model says disposable. That is NOT enough to authorise
        // deletion: no single fallible source is, and a hallucinated verdict must cost at
        // most one manual review, never a deleted receipt.
        let ruleResult = CategorizationResult(
            messageId: "m", category: .transactional, safetyTier: .review,
            confidence: 0.5, reason: "rules: ambiguous"
        )
        let modelSaysSafe = verdict("x@shop.com", category: .promotion, mustKeep: false)

        let merged = AICategorizationEngine.merge(rule: ruleResult, verdict: modelSaysSafe)

        XCTAssertEqual(
            merged.safetyTier, .review,
            "one model call must not move mail toward deletion on its own"
        )
    }

    func testAIVerdictCannotLoosenAStrongRuleFindingEvenWithCorroboration() {
        // A finding the rules EARNED is never loosened, whatever else agrees. An explicit
        // transactional domain match outranks both the model and the provider.
        let ruleResult = CategorizationResult(
            messageId: "m", category: .transactional, safetyTier: .review,
            confidence: 0.9, reason: "Transactional sender", evidence: .strong
        )
        let merged = AICategorizationEngine.merge(
            rule: ruleResult,
            verdict: verdict("x@shop.com", category: .promotion, mustKeep: false),
            providerCategory: .promotions
        )

        XCTAssertEqual(merged.safetyTier, .review)
        XCTAssertEqual(merged.category, .transactional, "a strong rule keeps its category")
    }

    func testCorroboratedVerdictMayResolveAProvisionalFinding() {
        // Two unrelated classifiers agree the mail is bulk marketing, and one of them read
        // the message. That is enough. Without this the app was inert: the evidence
        // invariant parked every weak finding in review, leaving 1 of 403 emails
        // actionable — including 104 the model had correctly called marketing.
        let ruleResult = CategorizationResult(
            messageId: "m", category: .unknown, safetyTier: .review,
            confidence: 0.4, reason: "No matching rule"
        )
        let merged = AICategorizationEngine.merge(
            rule: ruleResult,
            verdict: verdict("x@shop.com", category: .promotion, mustKeep: false),
            providerCategory: .promotions
        )

        XCTAssertEqual(merged.safetyTier, .safe)
        XCTAssertEqual(merged.category, .promotion)
        XCTAssertTrue(merged.reason.contains("Gmail"))
    }

    func testProviderDisagreementKeepsProvisionalMailInReview() {
        // Same verdict, but the provider filed this message under Updates — where bills
        // live. The disagreement is decided per MESSAGE, which is how a mixed sender like
        // info@email.ns.nl (46 promotional, 58 receipts) gets split correctly.
        let ruleResult = CategorizationResult(
            messageId: "m", category: .unknown, safetyTier: .review,
            confidence: 0.4, reason: "No matching rule"
        )
        let merged = AICategorizationEngine.merge(
            rule: ruleResult,
            verdict: verdict("info@email.ns.nl", category: .promotion, mustKeep: false),
            providerCategory: .updates
        )

        XCTAssertEqual(merged.safetyTier, .review)
    }

    func testVerdictMayAlwaysRaiseSafetyWithoutCorroboration() {
        // Raising safety needs no second opinion — the asymmetry is the whole point. Note
        // the provider says PROMOTIONS here and is simply outvoted: corroboration is a
        // requirement for loosening, never a licence to loosen.
        let ruleResult = CategorizationResult(
            messageId: "m", category: .promotion, safetyTier: .review,
            confidence: 0.5, reason: "weak guess"
        )
        let merged = AICategorizationEngine.merge(
            rule: ruleResult,
            verdict: verdict("colleague@example.com", category: .personal, isRealPerson: true),
            providerCategory: .promotions
        )

        XCTAssertEqual(merged.safetyTier, .protected_)
        XCTAssertTrue(merged.reason.contains("raised safety"))
    }

    func testVerdictNarrowsEvenAStrongRuleFinding() {
        // Narrowing a strong finding is still allowed — only loosening is restricted.
        let ruleResult = CategorizationResult(
            messageId: "m", category: .promotion, safetyTier: .safe,
            confidence: 0.85, reason: "Known promotional sender domain", evidence: .strong
        )
        let merged = AICategorizationEngine.merge(
            rule: ruleResult,
            verdict: verdict("x@shop.com", category: .transactional, mustKeep: true)
        )

        XCTAssertEqual(
            merged.safetyTier, .protected_,
            "the model may always argue for keeping, and that argument is a decision"
        )
    }

    func testVerdictNeverWeakensAProtectedContact() {
        let ruleResult = CategorizationResult(
            messageId: "m", category: .personal, safetyTier: .protected_,
            confidence: 0.95, reason: "From known contact", evidence: .strong
        )
        let merged = AICategorizationEngine.merge(
            rule: ruleResult,
            verdict: verdict("friend@example.com", category: .promotion, mustKeep: false),
            providerCategory: .promotions
        )

        XCTAssertEqual(merged.safetyTier, .protected_)
        XCTAssertEqual(merged.reason, "From known contact")
    }

    func testAIVerdictCanRaiseSafety() {
        // Rules thought this was disposable; the model recognises a real person.
        let ruleResult = CategorizationResult(
            messageId: "m", category: .notification, safetyTier: .safe,
            confidence: 0.45, reason: "rules: ambiguous local part"
        )
        let modelSaysPerson = verdict("info@garage.co.uk", category: .personal, isRealPerson: true)

        let merged = AICategorizationEngine.merge(rule: ruleResult, verdict: modelSaysPerson)

        XCTAssertEqual(merged.safetyTier, .protected_, "the model may protect on its own authority")
        XCTAssertEqual(merged.category, .personal)
    }

    func testMustKeepVerdictRaisesToReview() {
        let ruleResult = CategorizationResult(
            messageId: "m", category: .promotion, safetyTier: .safe,
            confidence: 0.5, reason: "rules: weak"
        )
        let merged = AICategorizationEngine.merge(
            rule: ruleResult,
            verdict: verdict("orders@shop.com", category: .transactional, mustKeep: true)
        )

        // protected_, not review: a model decision to KEEP is a decision, and filing it
        // under "needs review" is what made 131 decided emails look like pending work.
        XCTAssertEqual(merged.safetyTier, .protected_)
        XCTAssertEqual(merged.category, .transactional)
    }

    func testConfidentRuleKeepsItsCategory() {
        // A confident rule result is not overridden, only potentially made safer.
        let ruleResult = CategorizationResult(
            messageId: "m", category: .social, safetyTier: .safe,
            confidence: 0.9, reason: "rules: social platform",
            evidence: .strong
        )
        let merged = AICategorizationEngine.merge(
            rule: ruleResult,
            verdict: verdict("x@facebook.com", category: .promotion, mustKeep: true)
        )

        XCTAssertEqual(merged.category, .social, "a STRONG rule result keeps its category")
        XCTAssertEqual(
            merged.safetyTier, .protected_,
            "the model can still raise safety, and a keep decision is settled not pending"
        )
    }

    func testImpliedTierOrdering() {
        XCTAssertEqual(verdict("a", isRealPerson: true).impliedTier, .protected_)
        // review is now reserved for the ABSENCE of a decision, which is abstention only.
        XCTAssertEqual(verdict("a", mustKeep: true).impliedTier, .protected_)
        XCTAssertEqual(verdict("a", isUnsure: true).impliedTier, .review)
        XCTAssertEqual(verdict("a").impliedTier, .safe)
    }

    // MARK: - Selection

    func testOnlyAmbiguousSendersAreSentToTheModel() {
        let emails = [
            email("confident", sender: "a@shop.com"),
            email("weak", sender: "b@shop.com"),
            email("unknown", sender: "c@shop.com"),
            email("protected", sender: "friend@example.com"),
        ]
        let results: [String: CategorizationResult] = [
            "confident": .init(messageId: "confident", category: .promotion, safetyTier: .safe,
                               confidence: 0.9, reason: "", evidence: .strong),
            "weak": .init(messageId: "weak", category: .promotion, safetyTier: .review,
                          confidence: 0.45, reason: ""),
            "unknown": .init(messageId: "unknown", category: .unknown, safetyTier: .review,
                             confidence: 0.3, reason: ""),
            "protected": .init(messageId: "protected", category: .personal, safetyTier: .protected_,
                               confidence: 0.95, reason: "", evidence: .strong),
        ]

        let senders = AICategorizationEngine.sendersNeedingClassification(
            emails: emails,
            ruleResults: results
        )

        XCTAssertEqual(senders, ["b@shop.com", "c@shop.com"])
        XCTAssertFalse(senders.contains("a@shop.com"), "strong evidence needs no model call")
        XCTAssertFalse(senders.contains("friend@example.com"), "a contact is already settled")
    }

    // MARK: - Cascade behaviour

    func testTransportIsNotCalledWhenRulesAreConfident() async throws {
        let db = try AppDatabase.inMemory()
        var account = EmailAccount(email: "me@example.com", provider: .gmail, createdAt: Date())
        try await db.saveAccount(&account)

        let transport = MockTransport()
        let engine = AICategorizationEngine(
            rules: RuleBasedEngine(),
            transport: transport,
            cache: db,
            accountId: account.id!
        )

        // A known social platform resolves at 0.9 confidence from rules alone.
        _ = try await engine.categorize(emails: [
            email("m", sender: "notification@facebookmail.com")
        ])

        XCTAssertEqual(transport.callCount, 0, "deterministic signals must not cost a model call")
    }

    func testAmbiguousSenderIsClassifiedAndMerged() async throws {
        let db = try AppDatabase.inMemory()
        var account = EmailAccount(email: "me@example.com", provider: .gmail, createdAt: Date())
        try await db.saveAccount(&account)

        // info@ is deliberately only weak evidence in the rule engine.
        let sender = "info@thelocalgarage.co.uk"
        let transport = MockTransport(verdicts: [
            sender: verdict(sender, category: .personal, isRealPerson: true, confidence: 0.88)
        ])
        let engine = AICategorizationEngine(
            rules: RuleBasedEngine(),
            transport: transport,
            cache: db,
            accountId: account.id!
        )

        let results = try await engine.categorize(emails: [
            email("m", sender: sender, subject: "About your booking on Tuesday")
        ])

        XCTAssertEqual(transport.callCount, 1)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].category, .personal)
        XCTAssertEqual(results[0].safetyTier, .protected_)
        XCTAssertTrue(results[0].reason.contains("AI:"))
    }

    func testResultOrderMatchesInputOrder() async throws {
        let db = try AppDatabase.inMemory()
        var account = EmailAccount(email: "me@example.com", provider: .gmail, createdAt: Date())
        try await db.saveAccount(&account)

        let transport = MockTransport(verdicts: [
            "b@unknownsite.org": verdict("b@unknownsite.org")
        ])
        let engine = AICategorizationEngine(
            rules: RuleBasedEngine(),
            transport: transport,
            cache: db,
            accountId: account.id!
        )

        let emails = [
            email("first", sender: "a@unknownsite.org"),
            email("second", sender: "b@unknownsite.org"),
            email("third", sender: "c@unknownsite.org"),
        ]
        let results = try await engine.categorize(emails: emails)

        XCTAssertEqual(results.map(\.messageId), ["first", "second", "third"])
    }

    // MARK: - Caching

    func testVerdictsAreCachedAndReused() async throws {
        let db = try AppDatabase.inMemory()
        var account = EmailAccount(email: "me@example.com", provider: .gmail, createdAt: Date())
        try await db.saveAccount(&account)
        let accountId = account.id!

        let sender = "mystery@unknownsite.org"
        let transport = MockTransport(verdicts: [sender: verdict(sender)])

        func makeEngine() -> AICategorizationEngine {
            AICategorizationEngine(
                rules: RuleBasedEngine(),
                transport: transport,
                cache: db,
                accountId: accountId
            )
        }

        _ = try await makeEngine().categorize(emails: [email("m1", sender: sender)])
        XCTAssertEqual(transport.callCount, 1)

        // A rescan of the same sender must not pay again.
        _ = try await makeEngine().categorize(emails: [email("m2", sender: sender)])
        XCTAssertEqual(transport.callCount, 1, "a cached sender must not be re-classified")

        let count = try await db.cachedVerdictCount(
            accountId: accountId,
            modelId: transport.modelId,
            promptVersion: transport.promptVersion
        )
        XCTAssertEqual(count, 1)
    }

    func testChangingPromptVersionInvalidatesTheCache() async throws {
        let db = try AppDatabase.inMemory()
        var account = EmailAccount(email: "me@example.com", provider: .gmail, createdAt: Date())
        try await db.saveAccount(&account)
        let accountId = account.id!

        let sender = "mystery@unknownsite.org"
        let v1 = MockTransport(promptVersion: "sender.v1", verdicts: [sender: verdict(sender)])
        _ = try await AICategorizationEngine(
            rules: RuleBasedEngine(), transport: v1, cache: db, accountId: accountId
        ).categorize(emails: [email("m1", sender: sender)])
        XCTAssertEqual(v1.callCount, 1)

        // A new prompt is a different classifier — reusing old verdicts would hide that.
        let v2 = MockTransport(promptVersion: "sender.v2", verdicts: [sender: verdict(sender)])
        _ = try await AICategorizationEngine(
            rules: RuleBasedEngine(), transport: v2, cache: db, accountId: accountId
        ).categorize(emails: [email("m2", sender: sender)])
        XCTAssertEqual(v2.callCount, 1, "a prompt change must re-classify")
    }

    func testBatchingRespectsBatchSize() async throws {
        let db = try AppDatabase.inMemory()
        var account = EmailAccount(email: "me@example.com", provider: .gmail, createdAt: Date())
        try await db.saveAccount(&account)

        // Derived from the constant rather than restating it: batchSize is a quality/cost
        // tuning knob and was lowered from 50 to 10 to give each sender real attention, so a
        // hardcoded expectation here only asserts that nobody has retuned it.
        let senderCount = 120
        let expectedBatches = Int(
            (Double(senderCount) / Double(AICategorizationEngine.batchSize)).rounded(.up)
        )
        let emails = (0..<senderCount).map { email("m\($0)", sender: "s\($0)@unknownsite.org") }
        let transport = MockTransport()
        let engine = AICategorizationEngine(
            rules: RuleBasedEngine(), transport: transport, cache: db, accountId: account.id!
        )

        _ = try await engine.categorize(emails: emails)

        XCTAssertEqual(transport.callCount, expectedBatches)
        XCTAssertEqual(transport.sendersAsked.count, senderCount)
        XCTAssertTrue(
            transport.receivedBatches.allSatisfy { $0.count <= AICategorizationEngine.batchSize },
            "no batch may exceed the configured size"
        )
    }

    // MARK: - Prompt contract

    func testPromptIncludesOnlyMetadata() {
        let request = SenderClassificationRequest(
            senderEmail: "a@shop.com",
            displayName: "A Shop",
            sampleSubjects: ["50% off everything"],
            totalEmails: 12,
            hasUnsubscribe: true,
            averageIntervalDays: 3.5
        )
        let message = SenderClassificationPrompt.userMessage(for: [request])

        XCTAssertTrue(message.contains("a@shop.com"))
        XCTAssertTrue(message.contains("50% off everything"))
        XCTAssertTrue(message.contains("unsubscribe_header: true"))
    }

    func testSchemaEnumeratesEveryCategory() {
        guard let cases = SenderClassificationPrompt.outputSchema["properties"]?["verdicts"]?["items"]?["properties"]?["category"]?["enum"]?.arrayValue else {
            return XCTFail("schema shape changed")
        }
        XCTAssertEqual(
            Set(cases.compactMap(\.stringValue)),
            Set(EmailCategory.allCases.map(\.rawValue))
        )
    }

    // MARK: - Response parsing

    func testParseVerdictsFromWellFormedPayload() {
        let payload = JSONValue.object([
            "verdicts": .array([
                .object([
                    "senderEmail": "a@shop.com",
                    "category": "promotion",
                    "mustKeep": false,
                    "isRealPerson": false,
                    "confidence": 0.92,
                    "reason": "sale subjects, unsubscribe present",
                ])
            ])
        ])

        let verdicts = SenderClassificationPrompt.parseVerdicts(from: payload)

        XCTAssertEqual(verdicts.count, 1)
        XCTAssertEqual(verdicts[0].category, .promotion)
        XCTAssertFalse(verdicts[0].mustKeep)
        XCTAssertEqual(verdicts[0].confidence, 0.92)
    }

    func testUnknownCategoryForcesMustKeep() {
        // An unparseable category means we do not know what this is, so it must not
        // become more deletable than it was.
        let payload = JSONValue.object([
            "verdicts": .array([
                .object([
                    "senderEmail": "a@shop.com",
                    "category": "marketing-blast",
                    "mustKeep": false,
                    "isRealPerson": false,
                    "confidence": 0.99,
                    "reason": "made up category",
                ])
            ])
        ])

        let verdicts = SenderClassificationPrompt.parseVerdicts(from: payload)

        XCTAssertEqual(verdicts[0].category, .unknown)
        XCTAssertTrue(verdicts[0].mustKeep, "an unrecognised category must not be treated as disposable")
        XCTAssertLessThanOrEqual(verdicts[0].confidence, 0.3)
        XCTAssertEqual(verdicts[0].impliedTier, .protected_)
    }

    func testMalformedEntriesAreSkippedNotDefaulted() {
        let payload = JSONValue.object([
            "verdicts": .array([
                .object(["category": "promotion"]),                 // no sender
                .object(["senderEmail": "not-an-address"]),          // not an address
                .object([
                    "senderEmail": "good@shop.com",
                    "category": "newsletter",
                    "mustKeep": false,
                    "isRealPerson": false,
                    "confidence": 0.8,
                    "reason": "digest",
                ]),
            ])
        ])

        let verdicts = SenderClassificationPrompt.parseVerdicts(from: payload)

        XCTAssertEqual(verdicts.map(\.senderEmail), ["good@shop.com"])
    }

    func testConfidenceIsClamped() {
        let payload = JSONValue.object([
            "verdicts": .array([
                .object([
                    "senderEmail": "a@shop.com", "category": "promotion",
                    "mustKeep": false, "isRealPerson": false,
                    "confidence": 7.5, "reason": "out of range",
                ])
            ])
        ])

        XCTAssertEqual(SenderClassificationPrompt.parseVerdicts(from: payload)[0].confidence, 1.0)
    }

    func testMissingMustKeepDefaultsToSafeSide() {
        let payload = JSONValue.object([
            "verdicts": .array([
                .object([
                    "senderEmail": "a@shop.com", "category": "promotion",
                    "confidence": 0.8, "reason": "no mustKeep field",
                ])
            ])
        ])

        XCTAssertTrue(
            SenderClassificationPrompt.parseVerdicts(from: payload)[0].mustKeep,
            "an absent safety field must default to the cautious answer"
        )
    }
}
