import XCTest
@testable import TriageCore

/// Message-level classification: the pass that reads mail no pattern could describe.
final class MessageClassificationTests: XCTestCase {

    private func rule(
        _ id: String = "m",
        category: EmailCategory = .newsletter,
        tier: SafetyTier = .review
    ) -> CategorizationResult {
        CategorizationResult(
            messageId: id, category: category, safetyTier: tier,
            confidence: 0.5, reason: "sender pass could not decide", evidence: .weak
        )
    }

    private func verdict(
        _ id: String = "m",
        category: EmailCategory = .promotion,
        mustKeep: Bool = false,
        isUnsure: Bool = false,
        reason: String = "prize draw"
    ) -> MessageVerdict {
        MessageVerdict(
            messageId: id, category: category, mustKeep: mustKeep,
            confidence: 0.9, reason: reason, isUnsure: isUnsure
        )
    }

    // MARK: - The case this exists for

    func testMarketingNoPatternCouldHaveMatchedIsResolved() {
        // The motivating case. A rail operator's model-written patterns were
        // ["dagje uit", "eropuit", "voordelig", "acties"] and matched a handful of its 54
        // messages, because it writes fresh copy weekly. "Maak kans op een jaar gratis
        // treinen!" is plainly promotional and matches none of them. Reading the message does
        // what no pattern set can.
        let merged = AICategorizationEngine.mergeMessage(
            rule: rule(),
            verdict: verdict(reason: "prize draw for free train travel"),
            providerCategory: .promotions
        )

        XCTAssertEqual(merged.category, .promotion)
        XCTAssertEqual(merged.safetyTier, .safe)
        XCTAssertTrue(merged.reason.contains("AI read this message"))
        XCTAssertEqual(merged.evidence, .strong)
    }

    func testKeepDecisionSettlesWithoutCorroboration() {
        // Keeping cannot lose anything, so it needs no second source — the same asymmetry as
        // everywhere else in the pipeline.
        let merged = AICategorizationEngine.mergeMessage(
            rule: rule(),
            verdict: verdict(category: .transactional, mustKeep: true, reason: "an invoice"),
            providerCategory: nil
        )

        XCTAssertEqual(merged.safetyTier, .protected_)
        XCTAssertEqual(merged.category, .transactional)
    }

    func testDisposableVerdictAloneDoesNotAuthoriseDeletion() {
        // One model call is a single fallible source however well informed, and a hallucinated
        // "disposable" costs a real message. The category is still recorded so the user can
        // see the judgement.
        let merged = AICategorizationEngine.mergeMessage(
            rule: rule(),
            verdict: verdict(),
            providerCategory: .updates
        )

        XCTAssertEqual(merged.category, .promotion, "the judgement is recorded")
        XCTAssertEqual(merged.safetyTier, .review, "but it is not actionable on one source")
    }

    func testMessageLevelAbstentionStaysPending() {
        let merged = AICategorizationEngine.mergeMessage(
            rule: rule(),
            verdict: verdict(isUnsure: true),
            providerCategory: .promotions
        )

        XCTAssertEqual(merged.safetyTier, .review)
        XCTAssertTrue(merged.reason.contains("still could not tell"))
    }

    func testProtectedMailIsNeverReopened() {
        let merged = AICategorizationEngine.mergeMessage(
            rule: rule(tier: .protected_),
            verdict: verdict(),
            providerCategory: .promotions
        )
        XCTAssertEqual(merged.safetyTier, .protected_)
    }

    // MARK: - Parsing

    func testParsingIsFailSafeOnAnUnknownCategory() {
        let payload = JSONValue.object([
            "verdicts": .array([
                .object([
                    "messageId": "m1",
                    "category": "nonsense",
                    "mustKeep": false,
                    "confidence": 0.95,
                    "reason": "r",
                ])
            ])
        ])

        let verdicts = MessageClassificationPrompt.parseVerdicts(from: payload)

        XCTAssertEqual(verdicts.count, 1)
        XCTAssertEqual(verdicts[0].category, .unknown)
        XCTAssertTrue(verdicts[0].mustKeep, "an unparseable category must not be deletable")
        XCTAssertLessThanOrEqual(verdicts[0].confidence, 0.3)
        XCTAssertEqual(verdicts[0].impliedTier, .protected_)
    }

    func testEntryWithoutAnIdIsDropped() {
        let payload = JSONValue.object([
            "verdicts": .array([
                .object(["category": "promotion", "mustKeep": false, "confidence": 0.9, "reason": "r"])
            ])
        ])
        XCTAssertTrue(MessageClassificationPrompt.parseVerdicts(from: payload).isEmpty)
    }

    // MARK: - The prompt

    func testPromptCoversTheThreeThingsTheSenderPassCannotDo() {
        let prompt = MessageClassificationPrompt.system

        // Age, which is what separates a live service alert from expired history.
        XCTAssertTrue(prompt.contains("AGE MATTERS"))
        XCTAssertTrue(prompt.contains("7 January"))
        // Language, since the mail is largely Dutch.
        XCTAssertTrue(prompt.contains("NOT IN ENGLISH"))
        XCTAssertTrue(prompt.contains("maak kans op"))
        // Abstention, so an opaque subject is not guessed at.
        XCTAssertTrue(prompt.contains("SAY WHEN YOU CANNOT TELL"))
    }

    func testRenderedRequestCarriesAgeAndProviderLabel() {
        let body = MessageClassificationPrompt.userMessage(for: [
            MessageClassificationRequest(
                messageId: "m1",
                senderEmail: "info@email.ns.nl",
                displayName: "NS",
                subject: "7 januari minder treinen door winters weer",
                snippet: "Door de verwachte sneeuw rijden er minder treinen.",
                ageDays: 250,
                providerCategory: .updates,
                senderVerdictSummary: "mixed sender",
                hasUnsubscribe: true
            )
        ])

        XCTAssertTrue(body.contains("age_days: 250"))
        XCTAssertTrue(body.contains("provider_filed_under: Updates"))
        XCTAssertTrue(body.contains("preview:"))
        XCTAssertTrue(body.contains("7 januari"))
    }

    func testCorrectionsReachTheMessagePromptToo() {
        let prompt = MessageClassificationPrompt.systemPrompt(corrections: [
            CorrectionExample(
                senderEmail: "noreply@mail.vitens.nl", subjectPattern: nil,
                category: .transactional, mustKeep: true
            )
        ])
        XCTAssertTrue(prompt.contains("noreply@mail.vitens.nl"))
        XCTAssertTrue(prompt.contains("CORRECT by definition"))
    }
}
