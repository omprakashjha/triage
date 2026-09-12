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

    func testKeepDecisionAloneDrivesTheTierForEveryCategory() async throws {
        // Regression, found by the user: they set their broker's "daily activity statement"
        // to `notification` and unticked "never delete this automatically", and the mail
        // stayed in review — because the tier fell back to whether the CATEGORY is
        // typically disposable, and notifications are not. An explicit instruction was
        // being overruled by a heuristic. 27 emails were held by it.
        for category in EmailCategory.allCases {
            let disposable = UserCorrection(
                accountId: 1, senderEmail: "x@example.com",
                category: category, mustKeep: false
            )
            XCTAssertEqual(
                disposable.impliedTier, .safe,
                "\(category.rawValue) marked deletable must be actionable"
            )

            let kept = UserCorrection(
                accountId: 1, senderEmail: "x@example.com",
                category: category, mustKeep: true
            )
            XCTAssertEqual(
                kept.impliedTier, .protected_,
                "\(category.rawValue) marked keep must be protected"
            )
        }
    }

    func testNotificationCorrectionReachesTheActionableTierEndToEnd() async throws {
        // The user's exact case, through the engine rather than the model in isolation.
        let correction = UserCorrection(
            accountId: 1,
            senderEmail: "donotreply@interactivebrokers.com",
            subjectPattern: "daily activity statement",
            category: .notification,
            mustKeep: false
        )
        let engine = CorrectingEngine(base: RuleBasedEngine(), corrections: [correction])

        let results = try await engine.categorize(emails: [
            email(
                sender: "donotreply@interactivebrokers.com",
                subject: "Daily Activity Statement for 4 September"
            )
        ])

        XCTAssertEqual(results[0].safetyTier, .safe)
        XCTAssertEqual(results[0].category, .notification)
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
        // Settled, not pending: the model read this message and decided to keep it.
        XCTAssertEqual(receipt.impliedTier, .protected_)
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

    func testAbstentionCannotRaiseSafetyOverTwoAgreeingClassifiers() {
        // Regression from the live mailbox. NS is a mixed sender, so the model returned
        // subject splits; this message matched neither, and the resulting "keep" verdict
        // raised safety over mail the rules AND Gmail had both called marketing. 48 emails
        // were held out of the actionable tier by it. An unmatched split is a gap in the
        // model's pattern list, not evidence about the message.
        let corroborated = CategorizationResult(
            messageId: "m", category: .newsletter, safetyTier: .safe,
            confidence: 0.9,
            reason: "Bulk mail (List-Unsubscribe) — and Gmail also filed it under Promotions",
            evidence: .strong
        )
        let mixedSenderVerdict = SenderVerdict(
            senderEmail: "info@email.ns.nl",
            category: .promotion,
            mustKeep: false,
            isRealPerson: false,
            confidence: 0.75,
            reason: "Mixed sender",
            disposableSubjects: ["korting"],
            keepSubjects: ["factuur"]
        ).resolved(forSubject: "Beleef een betoverende kerstvakantie met NS Dagje Uit")

        XCTAssertTrue(mixedSenderVerdict.isUnsure, "an unmatched split is an abstention")

        let merged = AICategorizationEngine.merge(
            rule: corroborated,
            verdict: mixedSenderVerdict,
            providerCategory: .promotions
        )

        XCTAssertEqual(
            merged.safetyTier, .safe,
            "an abstention must not outrank two independent classifiers that agree"
        )
    }

    func testAbstentionLeavesUncertainMailInReview() {
        // The other side: where the rules were also unsure, an abstention changes nothing,
        // which is the same outcome as before by a more honest route.
        let weak = CategorizationResult(
            messageId: "m", category: .unknown, safetyTier: .review,
            confidence: 0.4, reason: "No matching rule"
        )
        let merged = AICategorizationEngine.merge(
            rule: weak,
            verdict: SenderVerdict(
                senderEmail: "x@unknown.example", category: .promotion, mustKeep: false,
                isRealPerson: false, confidence: 0.9, reason: "unsure", isUnsure: true
            ),
            providerCategory: .promotions
        )

        XCTAssertEqual(merged.safetyTier, .review)
    }

    func testWholeSubjectLinesAreRejectedAsFragments() {
        // Regression from the live mailbox. Asked in prose for fragments that generalise,
        // Haiku echoed whole subject lines back, each matching exactly the one message it
        // came from — which left 59 emails matching no pattern at all. A fragment is a rule
        // for unseen mail, so the word cap enforces in code what the prompt asks for.
        let payload = JSONValue.object([
            "verdicts": .array([
                .object([
                    "senderEmail": "info@email.ns.nl",
                    "category": "promotion",
                    "mustKeep": false,
                    "isRealPerson": false,
                    "confidence": 0.75,
                    "reason": "mixed",
                    "disposableSubjects": .array([
                        // Copied subject lines: must be dropped.
                        "zomer in eigen land met ns dagje uit-magazine",
                        "ontdek 12 provinciegidsen en geniet van kortingen",
                        // Genuine fragments: must survive.
                        "korting",
                        "dagje uit",
                    ]),
                    "keepSubjects": .array([
                        "let op: werkzaamheden almere centrum - weesp",
                        "werkzaamheden",
                    ]),
                ])
            ])
        ])

        let verdicts = SenderClassificationPrompt.parseVerdicts(from: payload)

        XCTAssertEqual(verdicts[0].disposableSubjects, ["korting", "dagje uit"])
        XCTAssertEqual(verdicts[0].keepSubjects, ["werkzaamheden"])
    }

    func testRepresentativeSubjectsSpreadAcrossTimeInsteadOfTakingTheNewest() {
        // The newest-N sample was actively misleading: a rail operator's most recent
        // subjects were all one winter campaign, so the model described that campaign and
        // missed the year-round receipts. Here the newest 10 are all one template and the
        // older mail is varied — the sampler must surface the variety.
        var emails: [EmailMetadata] = []
        let now = Date()
        for i in 0..<10 {
            emails.append(email(
                "new\(i)",
                sender: "info@email.ns.nl",
                subject: "Duurzame dinsdag: groen eropuit met de trein \(i)"
            ))
        }
        for (i, subject) in ["Uw factuur van maart", "Werkzaamheden Almere", "Uw reisoverzicht"]
            .enumerated()
        {
            var old = email("old\(i)", sender: "info@email.ns.nl", subject: subject)
            old.date = now.addingTimeInterval(-Double(i + 1) * 86400 * 90)
            emails.append(old)
        }

        let picked = AICategorizationEngine.representativeSubjects(
            of: emails.sorted { $0.date > $1.date }
        )

        XCTAssertTrue(
            picked.contains { $0.contains("factuur") },
            "the older transactional mail must be visible to the model"
        )
        XCTAssertLessThanOrEqual(
            picked.filter { $0.contains("Duurzame dinsdag") }.count, 2,
            "near-duplicate templates must not crowd out the variety"
        )
    }

    // MARK: - Subject-scoped golden labels

    func testEvaluatorScoresAgainstTheNarrowestMatchingLabel() {
        // A sender with two scopes: its receipts must be kept, its marketing may go. Scoring
        // both halves against one sender-wide label would mark correct behaviour wrong, which
        // is why labels needed the same scope corrections already had.
        let labels = [
            GoldenLabel(
                accountId: 1, senderEmail: "info@email.ns.nl",
                expectedCategory: .promotion, disposition: .disposable
            ),
            GoldenLabel(
                accountId: 1, senderEmail: "info@email.ns.nl", subjectPattern: "factuur",
                expectedCategory: .transactional, disposition: .mustKeep
            ),
        ]

        let receipt = email("a", sender: "info@email.ns.nl", subject: "Uw factuur van maart")
        let promo = email("b", sender: "info@email.ns.nl", subject: "Korting op reizen")

        let results = [
            CategorizationResult(
                messageId: "a", category: .transactional, safetyTier: .review,
                confidence: 0.9, reason: "kept", evidence: .strong
            ),
            CategorizationResult(
                messageId: "b", category: .promotion, safetyTier: .safe,
                confidence: 0.9, reason: "marketing", evidence: .strong
            ),
        ]

        let report = CategorizationEvaluator().evaluate(
            emails: [receipt, promo], results: results, labels: labels, accountId: 1
        )

        XCTAssertEqual(report.evaluatedEmails, 2, "both halves are scoreable")
        XCTAssertEqual(
            report.categoryAccuracy, 1.0,
            "each message scored against its own scope, so both are correct"
        )
    }

    func testWholeSenderLabelStillCoversUnscopedMail() {
        let labels = [
            GoldenLabel(
                accountId: 1, senderEmail: "x@shop.example",
                expectedCategory: .promotion, disposition: .disposable
            )
        ]
        let mail = email("a", sender: "x@shop.example", subject: "Anything at all")
        let results = [
            CategorizationResult(
                messageId: "a", category: .promotion, safetyTier: .safe,
                confidence: 0.9, reason: "r", evidence: .strong
            )
        ]

        let report = CategorizationEvaluator().evaluate(
            emails: [mail], results: results, labels: labels, accountId: 1
        )
        XCTAssertEqual(report.evaluatedEmails, 1)
    }

    func testReviewMeansUndecidedAndNothingElse() {
        // The whole point of the tier fix. Measured on a real mailbox, 219 emails sat in
        // review and 131 of them were there because the model had DECIDED to keep them —
        // finished work presented as an open question, which is why confirming 28 senders
        // produced no visible change and the user concluded the reviewing was not happening.
        //
        // review is now reserved for the absence of a decision.
        let decidedKeep = SenderVerdict(
            senderEmail: "bank@example.com", category: .transactional, mustKeep: true,
            isRealPerson: false, confidence: 0.95, reason: "statements"
        )
        let decidedDispose = SenderVerdict(
            senderEmail: "shop@example.com", category: .promotion, mustKeep: false,
            isRealPerson: false, confidence: 0.9, reason: "marketing"
        )
        let undecided = SenderVerdict(
            senderEmail: "who@example.com", category: .unknown, mustKeep: true,
            isRealPerson: false, confidence: 0.3, reason: "cannot tell", isUnsure: true
        )

        XCTAssertEqual(decidedKeep.impliedTier, .protected_, "a keep decision is settled")
        XCTAssertEqual(decidedDispose.impliedTier, .safe, "a dispose decision is settled")
        XCTAssertEqual(undecided.impliedTier, .review, "only an abstention is pending")
    }

    func testTheTierFixCannotMakeMailMoreDeletable() {
        // Guard on the direction of the change: every tier this moved went AWAY from
        // actionable, so it cannot cause data loss. If a future edit inverts that, this fails.
        for mustKeep in [true, false] {
            for unsure in [true, false] {
                let v = SenderVerdict(
                    senderEmail: "x@example.com", category: .promotion, mustKeep: mustKeep,
                    isRealPerson: false, confidence: 0.9, reason: "r", isUnsure: unsure
                )
                if mustKeep || unsure {
                    XCTAssertNotEqual(
                        v.impliedTier, .safe,
                        "keep or unsure must never be auto-actionable"
                    )
                }
            }
        }
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
