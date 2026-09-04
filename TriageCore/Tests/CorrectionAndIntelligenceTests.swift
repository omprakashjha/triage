import XCTest
@testable import TriageCore

/// Corrections, mixed-sender splits, abstention, and language-aware rule trust.
final class CorrectionAndIntelligenceTests: XCTestCase {

    private func email(
        _ id: String = UUID().uuidString,
        sender: String,
        subject: String,
        labels: [String]? = nil
    ) -> EmailMetadata {
        var e = EmailMetadata(
            accountId: 1,
            messageId: id,
            threadId: "t",
            sender: "Name <\(sender)>",
            senderEmail: sender,
            subject: subject,
            date: Date()
        )
        e.labels = labels
        return e
    }

    // MARK: - Corrections outrank everything

    func testCorrectionOverridesTheRules() async throws {
        // The rules would call this promotional on the strength of a listed domain. The
        // user has said otherwise, and the user is not guessing.
        let correction = UserCorrection(
            accountId: 1,
            senderEmail: "x@walmart.com",
            category: .transactional,
            mustKeep: true
        )
        let engine = CorrectingEngine(
            base: RuleBasedEngine(),
            corrections: [correction]
        )

        let results = try await engine.categorize(emails: [
            email(sender: "x@walmart.com", subject: "Weekend sale")
        ])

        XCTAssertEqual(results[0].category, .transactional)
        XCTAssertEqual(results[0].safetyTier, .protected_)
        XCTAssertEqual(results[0].confidence, 1.0)
        XCTAssertTrue(results[0].reason.contains("You set"))
    }

    func testSubjectScopedCorrectionOnlyAffectsMatchingMail() async throws {
        // The mixed-sender case, corrected by hand: the receipts are protected while the
        // marketing from the same address is left to the rules.
        let correction = UserCorrection(
            accountId: 1,
            senderEmail: "info@email.ns.nl",
            subjectPattern: "factuur",
            category: .transactional,
            mustKeep: true
        )
        let engine = CorrectingEngine(base: RuleBasedEngine(), corrections: [correction])

        let results = try await engine.categorize(emails: [
            email("a", sender: "info@email.ns.nl", subject: "Uw factuur van maart"),
            email("b", sender: "info@email.ns.nl", subject: "Aanbieding: korting op reizen"),
        ])
        let byId = Dictionary(uniqueKeysWithValues: results.map { ($0.messageId, $0) })

        XCTAssertEqual(byId["a"]?.safetyTier, .protected_)
        XCTAssertEqual(byId["a"]?.category, .transactional)
        XCTAssertNotEqual(byId["b"]?.safetyTier, .protected_, "the other half is untouched")
    }

    func testMoreSpecificCorrectionWinsOverWholeSender() async throws {
        let broad = UserCorrection(
            accountId: 1, senderEmail: "info@ns.nl",
            category: .promotion, mustKeep: false
        )
        let narrow = UserCorrection(
            accountId: 1, senderEmail: "info@ns.nl", subjectPattern: "factuur",
            category: .transactional, mustKeep: true
        )
        // Deliberately supplied in the unhelpful order.
        let engine = CorrectingEngine(base: RuleBasedEngine(), corrections: [broad, narrow])

        let results = try await engine.categorize(emails: [
            email(sender: "info@ns.nl", subject: "Uw factuur")
        ])

        XCTAssertEqual(results[0].category, .transactional)
        XCTAssertEqual(results[0].safetyTier, .protected_)
    }

    func testCorrectionCanMakeMailAutoActionableAlone() async throws {
        // Unlike a model verdict, a correction needs no corroboration. Refusing to honour
        // an explicit instruction is its own kind of failure.
        let correction = UserCorrection(
            accountId: 1,
            senderEmail: "noreply@somelist.example",
            category: .promotion,
            mustKeep: false
        )
        let engine = CorrectingEngine(base: RuleBasedEngine(), corrections: [correction])

        let results = try await engine.categorize(emails: [
            email(sender: "noreply@somelist.example", subject: "Bericht over uw account")
        ])

        XCTAssertEqual(results[0].safetyTier, .safe)
        XCTAssertEqual(results[0].evidence, .strong)
    }

    // MARK: - Mixed senders, split per message

    func testVerdictSplitAppliesPerMessage() {
        let verdict = SenderVerdict(
            senderEmail: "info@email.ns.nl",
            category: .promotion,
            mustKeep: false,
            isRealPerson: false,
            confidence: 0.9,
            reason: "Rail operator sending both offers and tickets",
            disposableSubjects: ["aanbieding", "korting"],
            keepSubjects: ["factuur", "reisoverzicht"]
        )

        let promo = verdict.resolved(forSubject: "Aanbieding: korting op reizen")
        XCTAssertFalse(promo.mustKeep)
        XCTAssertEqual(promo.impliedTier, .safe)

        let receipt = verdict.resolved(forSubject: "Uw factuur van maart")
        XCTAssertTrue(receipt.mustKeep)
        XCTAssertEqual(receipt.category, .transactional, "a kept message is not promotional")
        XCTAssertEqual(receipt.impliedTier, .review)
    }

    func testUnmatchedMessageFromAMixedSenderIsKept() {
        // The model described a split and this message fits neither side, so it is one the
        // model did not account for. Keeping it is the only safe reading.
        let verdict = SenderVerdict(
            senderEmail: "info@email.ns.nl",
            category: .promotion,
            mustKeep: false,
            isRealPerson: false,
            confidence: 0.9,
            reason: "mixed",
            disposableSubjects: ["aanbieding"],
            keepSubjects: ["factuur"]
        )

        let other = verdict.resolved(forSubject: "Storing op traject Utrecht")
        XCTAssertTrue(other.mustKeep)
        XCTAssertLessThanOrEqual(other.confidence, 0.6)
    }

    func testKeepPatternWinsWhenBothMatch() {
        let verdict = SenderVerdict(
            senderEmail: "x@shop.example",
            category: .promotion,
            mustKeep: false,
            isRealPerson: false,
            confidence: 0.9,
            reason: "mixed",
            disposableSubjects: ["sale"],
            keepSubjects: ["invoice"]
        )

        let both = verdict.resolved(forSubject: "Invoice for your sale items")
        XCTAssertTrue(both.mustKeep, "the asymmetry always favours keeping")
    }

    func testSenderWithNoSplitIsUnchanged() {
        let verdict = SenderVerdict(
            senderEmail: "x@shop.example",
            category: .promotion,
            mustKeep: false,
            isRealPerson: false,
            confidence: 0.9,
            reason: "plain promotional sender"
        )
        XCTAssertEqual(verdict.resolved(forSubject: "anything"), verdict)
    }

    // MARK: - Abstention

    func testAbstentionImpliesReviewNotAGuess() {
        let unsure = SenderVerdict(
            senderEmail: "x@unknown.example",
            category: .promotion,
            mustKeep: false,
            isRealPerson: false,
            confidence: 0.8,
            reason: "too few samples to judge",
            isUnsure: true
        )
        // Category says disposable and confidence is high, yet the tier is review: an
        // abstention is not a low-confidence guess, it is a refusal to guess.
        XCTAssertEqual(unsure.impliedTier, .review)
    }

    func testAbstentionCannotBeCorroboratedIntoAutoAction() {
        // The corroboration path must not launder an abstention into a deletion.
        let rule = CategorizationResult(
            messageId: "m", category: .unknown, safetyTier: .review,
            confidence: 0.4, reason: "No matching rule"
        )
        let merged = AICategorizationEngine.merge(
            rule: rule,
            verdict: SenderVerdict(
                senderEmail: "x@unknown.example", category: .promotion, mustKeep: false,
                isRealPerson: false, confidence: 0.9, reason: "unsure", isUnsure: true
            ),
            providerCategory: .promotions
        )
        XCTAssertEqual(merged.safetyTier, .review)
    }

    func testParsingReadsAbstentionAndSplits() {
        let payload = JSONValue.object([
            "verdicts": .array([
                .object([
                    "senderEmail": "info@email.ns.nl",
                    "category": "promotion",
                    "mustKeep": false,
                    "isRealPerson": false,
                    "confidence": 0.9,
                    "reason": "mixed rail operator",
                    "unsure": false,
                    "disposableSubjects": .array(["aanbieding", "korting"]),
                    // Two characters: must be dropped, since a fragment that short would
                    // match nearly every subject.
                    "keepSubjects": .array(["factuur", "ab"]),
                ])
            ])
        ])

        let verdicts = SenderClassificationPrompt.parseVerdicts(from: payload)

        XCTAssertEqual(verdicts.count, 1)
        XCTAssertEqual(verdicts[0].disposableSubjects, ["aanbieding", "korting"])
        XCTAssertEqual(verdicts[0].keepSubjects, ["factuur"], "short fragments are dropped")
        XCTAssertFalse(verdicts[0].isUnsure)
    }

    // MARK: - Language-aware rule trust

    func testDutchSubjectsAreDetected() {
        let foreign = [
            "Jaarafrekening van uw waterbedrijf",
            "Uw factuur is beschikbaar",
            "Ihre Rechnung für März",
            "Votre facture est disponible",
            "Bekijk het overzicht van uw kosten",
        ]
        for subject in foreign {
            XCTAssertTrue(
                RuleBasedEngine.subjectIsProbablyNotEnglish(subject),
                "\(subject) should read as non-English"
            )
        }
    }

    func testEnglishSubjectsAreNotFlagged() {
        let english = [
            "Your statement is ready",
            "Weekend sale — 40% off everything",
            "Your order has shipped",
            "Weekly digest: what happened",
        ]
        for subject in english {
            XCTAssertFalse(
                RuleBasedEngine.subjectIsProbablyNotEnglish(subject),
                "\(subject) should read as English"
            )
        }
    }

    func testEnglishKeywordOnForeignSubjectLosesAuthority() {
        let strongSubjectFinding = CategorizationResult(
            messageId: "m", category: .promotion, safetyTier: .safe,
            confidence: 0.9, reason: "Promotional subject pattern (\"sale\")",
            evidence: .strong
        )
        let demoted = RuleBasedEngine.discountingEnglishPatternsOnForeignMail(
            strongSubjectFinding,
            email: email(sender: "x@shop.nl", subject: "Sale: bekijk uw persoonlijke aanbieding")
        )

        XCTAssertEqual(demoted.evidence, .weak)
        XCTAssertLessThan(demoted.confidence, 0.7, "and so is routed to the model")
    }

    func testListedDomainKeepsItsAuthorityOnForeignMail() {
        // A domain match means the same thing in every language, so this must be untouched.
        let domainFinding = CategorizationResult(
            messageId: "m", category: .transactional, safetyTier: .review,
            confidence: 0.9, reason: "Transactional sender", evidence: .strong
        )
        let unchanged = RuleBasedEngine.discountingEnglishPatternsOnForeignMail(
            domainFinding,
            email: email(sender: "noreply@rabobank.nl", subject: "Uw rekeningoverzicht")
        )

        XCTAssertEqual(unchanged.evidence, .strong)
    }

    // MARK: - Prompt feedback

    func testCorrectionsAppearInTheSystemPrompt() {
        let prompt = SenderClassificationPrompt.systemPrompt(corrections: [
            CorrectionExample(
                senderEmail: "noreply@mail.vitens.nl",
                subjectPattern: nil,
                category: .transactional,
                mustKeep: true
            )
        ])

        XCTAssertTrue(prompt.contains("noreply@mail.vitens.nl"))
        XCTAssertTrue(prompt.contains("transactional"))
        XCTAssertTrue(prompt.contains("must be kept"))
        XCTAssertTrue(prompt.contains("CORRECT by definition"))
    }

    func testPromptWithoutCorrectionsIsUnchanged() {
        XCTAssertEqual(
            SenderClassificationPrompt.systemPrompt(corrections: []),
            SenderClassificationPrompt.system
        )
    }

    func testPromptInstructsForLanguageAndAbstention() {
        let prompt = SenderClassificationPrompt.system
        XCTAssertTrue(prompt.contains("NOT IN ENGLISH"))
        XCTAssertTrue(prompt.contains("jaarafrekening"))
        XCTAssertTrue(prompt.contains("SAY WHEN YOU DO NOT KNOW"))
        XCTAssertTrue(prompt.contains("MANY SENDERS ARE MIXED"))
    }
}
