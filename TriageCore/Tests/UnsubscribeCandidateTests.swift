import XCTest
@testable import TriageCore

/// Ranking subscriptions by what ending them prevents.
final class UnsubscribeCandidateTests: XCTestCase {
    private var db: AppDatabase!
    private var accountId: Int64!
    private let now = Date()

    override func setUp() async throws {
        db = try AppDatabase.inMemory()
        var account = EmailAccount(email: "me@example.com", provider: .gmail, createdAt: Date())
        try await db.saveAccount(&account)
        accountId = account.id!
    }

    private func mail(
        _ id: String,
        sender: String,
        daysAgo: Double,
        unsubscribe: Bool = true,
        oneClick: Bool = true,
        tier: SafetyTier = .safe
    ) -> EmailMetadata {
        var e = EmailMetadata(
            accountId: accountId,
            messageId: id,
            threadId: "t-\(id)",
            sender: "Name <\(sender)>",
            senderEmail: sender,
            subject: "Subject \(id)",
            date: now.addingTimeInterval(-daysAgo * 86_400)
        )
        e.hasListUnsubscribe = unsubscribe
        e.supportsOneClickUnsubscribe = oneClick
        e.safetyTier = tier
        e.category = .promotion
        return e
    }

    // MARK: - Ranking

    func testRanksByForwardFlowNotStoredVolume() async throws {
        // The measurement that motivated the whole design: on a real mailbox a sender with 65 stored
        // messages was sending 1.3 a month while one with 2 stored was sending 2.0 a month.
        // Unsubscribing stops future mail only, so cadence must win over accumulation.
        var emails: [EmailMetadata] = []
        // Dormant hoarder: 30 messages, all roughly a year ago, spread over a long span.
        for i in 0..<30 {
            emails.append(mail("old\(i)", sender: "hoarder@example.com", daysAgo: 300 + Double(i)))
        }
        // Live subscriber: 8 messages in the last month.
        for i in 0..<8 {
            emails.append(mail("new\(i)", sender: "live@example.com", daysAgo: Double(i) * 3))
        }
        try await db.upsertEmails(emails)

        let ranked = try await db.unsubscribeCandidates(accountId: accountId, now: now)
        XCTAssertEqual(ranked.first?.senderEmail, "live@example.com",
                       "the live sender must outrank the one with four times the stored mail")
        // Deliberately NOT asserting that the rate decreases down the list. Once recommendation
        // leads the sort, rate is only monotonic WITHIN a group — and the dormant hoarder's lifetime
        // rate is in fact the higher of the two, which is exactly why rate alone was the wrong sort
        // key. What matters is that the actionable sender is offered and the silent one is not.
        XCTAssertEqual(ranked.first?.recommendation(asOf: now), .unsubscribe)
        XCTAssertEqual(ranked.last?.recommendation(asOf: now), .dormant)
    }

    func testSendersWithNoUnsubscribeHeaderAreExcluded() async throws {
        try await db.upsertEmails([
            mail("a", sender: "nolink@example.com", daysAgo: 1, unsubscribe: false),
            mail("b", sender: "haslink@example.com", daysAgo: 1),
        ])
        let ranked = try await db.unsubscribeCandidates(accountId: accountId)
        XCTAssertEqual(ranked.map(\.senderEmail), ["haslink@example.com"],
                       "offering a button that cannot work is worse than not listing the sender")
    }

    func testAlreadyAttemptedSendersSinkButRemain() async throws {
        try await db.upsertEmails([
            mail("a", sender: "tried@example.com", daysAgo: 1),
            mail("b", sender: "tried@example.com", daysAgo: 8),
            mail("c", sender: "fresh@example.com", daysAgo: 30),
        ])
        try await db.recordUnsubscribeAttempt(
            UnsubscribeAttempt(
                senderEmail: "tried@example.com",
                method: "one-click",
                succeeded: true
            ),
            accountId: accountId
        )

        let ranked = try await db.unsubscribeCandidates(accountId: accountId)
        XCTAssertEqual(ranked.last?.senderEmail, "tried@example.com")
        XCTAssertTrue(ranked.last!.alreadyAttempted,
                      "an ignored unsubscribe is itself worth seeing, so it must not vanish")
    }

    // MARK: - Recommendation

    func testADormantSenderIsNotWorthUnsubscribing() {
        let c = UnsubscribeCandidate(
            senderEmail: "quiet@example.com", displayName: "Quiet",
            storedVolume: 50, projectedYearlyVolume: 50, oneClickCount: 50, mustKeepCount: 0,
            firstSeen: now.addingTimeInterval(-800 * 86_400),
            lastSeen: now.addingTimeInterval(-300 * 86_400)
        )
        XCTAssertEqual(c.recommendation(asOf: now), .dormant,
                       "a sender that stopped writing cannot be stopped again")
    }

    func testCollateralIsFlaggedFromEitherSource() {
        let byTier = UnsubscribeCandidate(
            senderEmail: "mixed@example.com", displayName: "Mixed",
            storedVolume: 40, projectedYearlyVolume: 40, oneClickCount: 40, mustKeepCount: 7,
            firstSeen: now.addingTimeInterval(-365 * 86_400), lastSeen: now
        )
        XCTAssertTrue(byTier.hasCollateral)
        XCTAssertEqual(byTier.recommendation(asOf: now), .unsubscribeWithCollateral)

        // The model's own keep list counts too — it is the only place some of this is recorded.
        let byModel = UnsubscribeCandidate(
            senderEmail: "utility@example.com", displayName: "Utility",
            storedVolume: 40, projectedYearlyVolume: 40, oneClickCount: 40, mustKeepCount: 0,
            modelKeepSubjects: ["jaarafrekening", "meterstand"],
            firstSeen: now.addingTimeInterval(-365 * 86_400), lastSeen: now
        )
        XCTAssertTrue(byModel.hasCollateral)
        XCTAssertEqual(byModel.recommendation(asOf: now), .unsubscribeWithCollateral)
    }

    func testACleanLiveSenderIsRecommendedOutright() {
        let c = UnsubscribeCandidate(
            senderEmail: "spam@example.com", displayName: "Spam",
            storedVolume: 20, projectedYearlyVolume: 24, oneClickCount: 20, mustKeepCount: 0,
            firstSeen: now.addingTimeInterval(-300 * 86_400), lastSeen: now
        )
        XCTAssertEqual(c.recommendation(asOf: now), .unsubscribe)
        XCTAssertFalse(c.hasCollateral)
    }

    func testATrickleIsNotWorthTheDecision() {
        let c = UnsubscribeCandidate(
            senderEmail: "rare@example.com", displayName: "Rare",
            storedVolume: 2, projectedYearlyVolume: 2, oneClickCount: 2, mustKeepCount: 0,
            firstSeen: now.addingTimeInterval(-300 * 86_400), lastSeen: now
        )
        XCTAssertEqual(c.recommendation(asOf: now), .notWorthIt,
                       "two emails a year costs less attention than deciding about it")
    }

    func testTwoMessagesNeverEarnARecommendationHoweverRecent() {
        // Measured on the real mailbox: a sender first seen three weeks ago with two messages
        // projected to 24 a year and ranked above a sender with sixty-five. Below three observed
        // messages there is no cadence, only a coincidence.
        let c = UnsubscribeCandidate(
            senderEmail: "new@example.com", displayName: "New",
            storedVolume: 2, projectedYearlyVolume: 24, oneClickCount: 2, mustKeepCount: 0,
            firstSeen: now.addingTimeInterval(-21 * 86_400), lastSeen: now
        )
        XCTAssertEqual(c.recommendation(asOf: now), .notWorthIt)
    }

    func testAShortWindowCannotOutrankALongRecord() async throws {
        // Three messages in three weeks must not project above a sender with a multi-year record.
        var emails: [EmailMetadata] = []
        for i in 0..<3 {
            emails.append(mail("new\(i)", sender: "recent@example.com", daysAgo: Double(i) * 7))
        }
        for i in 0..<40 {
            emails.append(mail("old\(i)", sender: "steady@example.com", daysAgo: Double(i) * 18))
        }
        try await db.upsertEmails(emails)

        let ranked = try await db.unsubscribeCandidates(accountId: accountId, now: now)
        XCTAssertEqual(ranked.first?.senderEmail, "steady@example.com",
                       "a quarter-long floor stops a three-week window flattering a new sender")
    }

    func testAShortBurstDoesNotProjectToAnAbsurdRate() async throws {
        // Three messages in two days must not annualise to 500 a year.
        try await db.upsertEmails([
            mail("a", sender: "burst@example.com", daysAgo: 0),
            mail("b", sender: "burst@example.com", daysAgo: 1),
            mail("c", sender: "burst@example.com", daysAgo: 2),
        ])
        let ranked = try await db.unsubscribeCandidates(accountId: accountId)
        XCTAssertLessThanOrEqual(ranked.first!.projectedYearlyVolume, 40,
                                 "a sub-month span is floored at a month to stop wild projections")
    }
}
