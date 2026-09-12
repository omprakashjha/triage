import XCTest
@testable import TriageCore

/// The decision queue and the ground truth it collects.
final class ActiveLearningTests: XCTestCase {
    private var db: AppDatabase!
    private var accountId: Int64!

    private let model = "test-model"
    private let prompt = "test.v1"

    override func setUp() async throws {
        db = try AppDatabase.inMemory()
        var account = EmailAccount(email: "me@example.com", provider: .gmail, createdAt: Date())
        try await db.saveAccount(&account)
        accountId = account.id!
    }

    private func insert(
        sender: String,
        subject: String = "Subject",
        tier: SafetyTier,
        category: EmailCategory = .promotion,
        count: Int = 1
    ) async throws {
        for i in 0..<count {
            var email = EmailMetadata(
                accountId: accountId,
                messageId: "\(sender)-\(subject)-\(i)-\(UUID().uuidString)",
                threadId: "t",
                sender: "Name <\(sender)>",
                senderEmail: sender,
                subject: subject,
                date: Date()
            )
            email.category = category
            email.safetyTier = tier
            email.categoryReason = "seeded"
            try await db.upsertEmails([email])
        }
    }

    // MARK: - Ranking

    func testCandidatesAreRankedByHowMuchOneDecisionResolves() async throws {
        try await insert(sender: "big@example.com", tier: .review, count: 20)
        try await insert(sender: "small@example.com", tier: .review, count: 3)
        try await insert(sender: "medium@example.com", tier: .review, count: 9)

        let candidates = try await db.triageCandidates(
            accountId: accountId, modelId: model, promptVersion: prompt
        )

        XCTAssertEqual(
            candidates.map(\.senderEmail),
            ["big@example.com", "medium@example.com", "small@example.com"],
            "the queue exists to put the highest-leverage decision first"
        )
        XCTAssertEqual(candidates.first?.pendingCount, 20)
    }

    func testSendersWithNothingAwaitingReviewAreNotAskedAbout() async throws {
        try await insert(sender: "settled@example.com", tier: .safe, count: 12)
        try await insert(sender: "pending@example.com", tier: .review, count: 2)

        let candidates = try await db.triageCandidates(
            accountId: accountId, modelId: model, promptVersion: prompt
        )

        XCTAssertEqual(candidates.map(\.senderEmail), ["pending@example.com"])
    }

    func testProtectedSendersAreNotAskedAbout() async throws {
        // A contact is settled by stronger evidence than anything this screen could collect.
        try await insert(sender: "friend@example.com", tier: .protected_, count: 5)

        let candidates = try await db.triageCandidates(
            accountId: accountId, modelId: model, promptVersion: prompt
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    func testConfirmedSendersAreNotAskedAgain() async throws {
        // Regression. The exclusion checked userCorrection only, and a confirmation
        // deliberately writes no correction — so confirming a sender did nothing visible: the
        // candidate came straight back at the top of the queue and the same decision
        // reappeared indefinitely. The existing exclusion test covered corrections and this
        // path had none, which is exactly the gap that let it ship.
        try await insert(sender: "confirmed@example.com", tier: .review, count: 18)
        try await insert(sender: "fresh@example.com", tier: .review, count: 2)

        try await db.confirmVerdict(
            accountId: accountId, senderEmail: "confirmed@example.com",
            category: .transactional, mustKeep: true
        )

        let candidates = try await db.triageCandidates(
            accountId: accountId, modelId: model, promptVersion: prompt
        )

        XCTAssertEqual(
            candidates.map(\.senderEmail), ["fresh@example.com"],
            "a confirmed sender has been ruled on and must not be asked about again"
        )
    }

    func testConfirmingIsIdempotent() async throws {
        // The user pressed the button repeatedly when nothing appeared to happen. That must
        // leave one label, not a pile of them.
        try await insert(sender: "x@example.com", tier: .review, count: 4)
        for _ in 0..<5 {
            try await db.confirmVerdict(
                accountId: accountId, senderEmail: "x@example.com",
                category: .promotion, mustKeep: false
            )
        }
        let labels = try await db.fetchGoldenLabels(accountId: accountId)
        XCTAssertEqual(labels.count, 1)
    }

    func testAlreadyCorrectedSendersAreNotAskedAgain() async throws {
        // The only resource this feature spends is the user's attention, so asking twice is
        // the one thing it must not do.
        try await insert(sender: "decided@example.com", tier: .review, count: 30)
        try await insert(sender: "undecided@example.com", tier: .review, count: 4)
        try await db.saveCorrection(
            UserCorrection(
                accountId: accountId, senderEmail: "decided@example.com",
                category: .transactional, mustKeep: true
            )
        )

        let candidates = try await db.triageCandidates(
            accountId: accountId, modelId: model, promptVersion: prompt
        )

        XCTAssertEqual(
            candidates.map(\.senderEmail), ["undecided@example.com"],
            "the higher-volume sender is skipped because it has already been ruled on"
        )
    }

    func testSubjectScopedCorrectionStillSuppressesTheSender() async throws {
        // Deliberate: having split a sender once, the user has engaged with it, and re-asking
        // about the whole sender would invite a broad answer that overwrites their narrow one.
        try await insert(sender: "mixed@example.com", tier: .review, count: 10)
        try await db.saveCorrection(
            UserCorrection(
                accountId: accountId, senderEmail: "mixed@example.com",
                subjectPattern: "factuur", category: .transactional, mustKeep: true
            )
        )

        let candidates = try await db.triageCandidates(
            accountId: accountId, modelId: model, promptVersion: prompt
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    // MARK: - What a confirmation is worth

    func testConfirmationRecordsGroundTruthWithoutChangingBehaviour() async throws {
        try await insert(sender: "x@example.com", tier: .review, count: 3)

        try await db.confirmVerdict(
            accountId: accountId, senderEmail: "x@example.com",
            category: .promotion, mustKeep: true
        )

        let labels = try await db.fetchGoldenLabels(accountId: accountId)
        XCTAssertEqual(labels.count, 1)
        XCTAssertEqual(LabelProvenance(note: labels.first?.note), .confirmation)

        // The crucial half: no correction, so the pipeline is unchanged and the label can
        // actually measure it. A label derived from a correction cannot.
        let corrections = try await db.corrections(accountId: accountId)
        XCTAssertTrue(corrections.isEmpty, "a confirmation must not alter the pipeline")
    }

    func testAgreementRateCountsConfirmationsAgainstOverturnedVerdicts() async throws {
        try await db.confirmVerdict(
            accountId: accountId, senderEmail: "a@example.com",
            category: .promotion, mustKeep: false
        )
        try await db.confirmVerdict(
            accountId: accountId, senderEmail: "b@example.com",
            category: .newsletter, mustKeep: false
        )
        // One overturned: a correction plus a correction-provenance label.
        try await db.saveCorrection(
            UserCorrection(
                accountId: accountId, senderEmail: "c@example.com",
                category: .transactional, mustKeep: true
            )
        )
        try await db.saveGoldenLabel(
            GoldenLabel(
                accountId: accountId, senderEmail: "c@example.com",
                expectedCategory: .transactional, disposition: .mustKeep,
                note: LabelProvenance.correction.note
            )
        )

        let rate = try await db.agreementRate(accountId: accountId)
        XCTAssertEqual(rate.confirmed, 2)
        XCTAssertEqual(rate.overturned, 1)
    }

    func testProvenanceDistinguishesMeasurableLabelsFromCircularOnes() {
        XCTAssertEqual(LabelProvenance(note: "Confirmed the model's verdict"), .confirmation)
        XCTAssertEqual(LabelProvenance(note: "From a user correction"), .correction)
        XCTAssertNil(LabelProvenance(note: "something else"))
        XCTAssertNil(LabelProvenance(note: nil))
    }
}
