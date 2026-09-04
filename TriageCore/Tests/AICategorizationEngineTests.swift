import XCTest
@testable import TriageCore

/// A transport that returns scripted verdicts and records what it was asked.
private final class MockTransport: LLMTransport, @unchecked Sendable {
    let modelId: String
    let promptVersion: String
    private(set) var receivedBatches: [[SenderClassificationRequest]] = []
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

    func classify(senders: [SenderClassificationRequest]) async throws -> [SenderVerdict] {
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
        confidence: Double = 0.9
    ) -> SenderVerdict {
        SenderVerdict(
            senderEmail: sender,
            category: category,
            mustKeep: mustKeep,
            isRealPerson: isRealPerson,
            confidence: confidence,
            reason: "mock reason"
        )
    }

    // MARK: - The safety guarantee

    func testAIVerdictCannotLoosenSafety() {
        // Rules said this needs review. The model disagrees and says it is disposable.
        // Safety must NOT be loosened — a hallucinated verdict must cost at most one
        // manual review, never a deleted receipt.
        let ruleResult = CategorizationResult(
            messageId: "m", category: .transactional, safetyTier: .review,
            confidence: 0.5, reason: "rules: ambiguous"
        )
        let modelSaysSafe = verdict("x@shop.com", category: .promotion, mustKeep: false)

        let merged = AICategorizationEngine.merge(rule: ruleResult, verdict: modelSaysSafe)

        XCTAssertEqual(merged.safetyTier, .review, "the model must never move mail toward deletion")
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

        XCTAssertEqual(merged.safetyTier, .review)
        XCTAssertEqual(merged.category, .transactional)
    }

    func testConfidentRuleKeepsItsCategory() {
        // A confident rule result is not overridden, only potentially made safer.
        let ruleResult = CategorizationResult(
            messageId: "m", category: .social, safetyTier: .safe,
            confidence: 0.9, reason: "rules: social platform"
        )
        let merged = AICategorizationEngine.merge(
            rule: ruleResult,
            verdict: verdict("x@facebook.com", category: .promotion, mustKeep: true)
        )

        XCTAssertEqual(merged.category, .social, "a confident rule keeps its category")
        XCTAssertEqual(merged.safetyTier, .review, "but the model can still raise safety")
    }

    func testImpliedTierOrdering() {
        XCTAssertEqual(verdict("a", isRealPerson: true).impliedTier, .protected_)
        XCTAssertEqual(verdict("a", mustKeep: true).impliedTier, .review)
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
                               confidence: 0.9, reason: ""),
            "weak": .init(messageId: "weak", category: .promotion, safetyTier: .review,
                          confidence: 0.45, reason: ""),
            "unknown": .init(messageId: "unknown", category: .unknown, safetyTier: .review,
                             confidence: 0.3, reason: ""),
            "protected": .init(messageId: "protected", category: .personal, safetyTier: .protected_,
                               confidence: 0.95, reason: ""),
        ]

        let senders = AICategorizationEngine.sendersNeedingClassification(
            emails: emails,
            ruleResults: results
        )

        XCTAssertEqual(senders, ["b@shop.com", "c@shop.com"])
        XCTAssertFalse(senders.contains("a@shop.com"), "confident rules need no model call")
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

        // 120 distinct unresolvable senders -> 3 batches at 50 per call.
        let emails = (0..<120).map { email("m\($0)", sender: "s\($0)@unknownsite.org") }
        let transport = MockTransport()
        let engine = AICategorizationEngine(
            rules: RuleBasedEngine(), transport: transport, cache: db, accountId: account.id!
        )

        _ = try await engine.categorize(emails: emails)

        XCTAssertEqual(transport.callCount, 3)
        XCTAssertEqual(transport.sendersAsked.count, 120)
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
        XCTAssertEqual(verdicts[0].impliedTier, .review)
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
