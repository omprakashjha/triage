import XCTest
@testable import TriageCore

final class UnsubscribeTests: XCTestCase {

    // MARK: - Mechanism selection (no network)

    func testPrefersBrowserWhenOneClickNotAdvertised() async throws {
        let service = UnsubscribeService()
        let header = "<https://shop.com/unsub?token=abc>, <mailto:unsub@shop.com>"

        // Without List-Unsubscribe-Post the URL may be a GET-only confirm page,
        // so we must NOT blind-POST to it.
        let outcome = try await service.unsubscribe(header: header, supportsOneClick: false)

        XCTAssertEqual(outcome, .needsBrowser(URL(string: "https://shop.com/unsub?token=abc")!))
    }

    func testFallsBackToMailtoWhenNoHTTPOption() async throws {
        let service = UnsubscribeService()
        let outcome = try await service.unsubscribe(
            header: "<mailto:unsub@shop.com>",
            supportsOneClick: true
        )
        XCTAssertEqual(outcome, .needsEmail("unsub@shop.com"))
    }

    func testUnavailableWhenHeaderHasNoUsableLink() async throws {
        let service = UnsubscribeService()
        let outcome = try await service.unsubscribe(header: "not a real header", supportsOneClick: false)
        XCTAssertEqual(outcome, .unavailable)
    }

    func testHeaderParsingExtractsBothMechanisms() {
        let options = EmailHeaderParser.parseListUnsubscribe(
            "<mailto:a@b.com>, <https://x.com/u>"
        )
        XCTAssertEqual(options.count, 2)
    }

    // MARK: - Verification

    func testSuccessfulUnsubscribeWithLaterMailIsFlaggedIgnored() {
        let attempt = UnsubscribeAttempt(
            senderEmail: "spam@shop.com",
            attemptedAt: Date().addingTimeInterval(-30 * 86400),
            method: "one-click",
            succeeded: true
        )

        // Mail 5 days after the attempt is inside the grace period.
        let withinGrace = Date().addingTimeInterval(-26 * 86400)
        XCTAssertFalse(attempt.wasIgnored(latestMailDate: withinGrace))

        // Mail 20 days after the attempt means they ignored it.
        let afterGrace = Date().addingTimeInterval(-10 * 86400)
        XCTAssertTrue(attempt.wasIgnored(latestMailDate: afterGrace))
    }

    func testFailedAttemptIsNeverFlaggedIgnored() {
        let attempt = UnsubscribeAttempt(
            senderEmail: "x@shop.com",
            attemptedAt: Date().addingTimeInterval(-60 * 86400),
            method: "browser",
            succeeded: false
        )
        XCTAssertFalse(
            attempt.wasIgnored(latestMailDate: Date()),
            "an attempt that never completed cannot have been ignored"
        )
    }

    // MARK: - Persistence

    func testAttemptRoundTripAndUpsert() async throws {
        let db = try AppDatabase.inMemory()
        var account = EmailAccount(email: "me@example.com", provider: .gmail, createdAt: Date())
        try await db.saveAccount(&account)
        let accountId = account.id!

        try await db.recordUnsubscribeAttempt(
            UnsubscribeAttempt(senderEmail: "a@shop.com", method: "browser", succeeded: false),
            accountId: accountId
        )
        try await db.recordUnsubscribeAttempt(
            UnsubscribeAttempt(senderEmail: "a@shop.com", method: "one-click", succeeded: true),
            accountId: accountId
        )

        let attempts = try await db.fetchUnsubscribeAttempts(accountId: accountId)
        XCTAssertEqual(attempts.count, 1, "a retry should update the record, not duplicate it")
        XCTAssertEqual(attempts[0].method, "one-click")
        XCTAssertTrue(attempts[0].succeeded)
    }

    func testLatestUnsubscribeInfoUsesNewestMessage() async throws {
        let db = try AppDatabase.inMemory()
        var account = EmailAccount(email: "me@example.com", provider: .gmail, createdAt: Date())
        try await db.saveAccount(&account)
        let accountId = account.id!

        try await db.batchUpsertEmails([
            EmailMetadata(
                accountId: accountId, messageId: "old", sender: "S", senderEmail: "news@shop.com",
                subject: "Old", date: Date().addingTimeInterval(-100 * 86400),
                hasListUnsubscribe: true,
                listUnsubscribeHeader: "<https://shop.com/expired>",
                supportsOneClickUnsubscribe: false
            ),
            EmailMetadata(
                accountId: accountId, messageId: "new", sender: "S", senderEmail: "news@shop.com",
                subject: "New", date: Date(),
                hasListUnsubscribe: true,
                listUnsubscribeHeader: "<https://shop.com/current>",
                supportsOneClickUnsubscribe: true
            ),
        ])

        let info = try await db.latestUnsubscribeInfo(accountId: accountId, senderEmail: "news@shop.com")

        // Senders rotate unsubscribe URLs, so the newest header is the live one.
        XCTAssertEqual(info?.header, "<https://shop.com/current>")
        XCTAssertEqual(info?.supportsOneClick, true)
    }

    func testNoUnsubscribeInfoForSenderWithoutHeader() async throws {
        let db = try AppDatabase.inMemory()
        var account = EmailAccount(email: "me@example.com", provider: .gmail, createdAt: Date())
        try await db.saveAccount(&account)
        let accountId = account.id!

        try await db.batchUpsertEmails([
            EmailMetadata(
                accountId: accountId, messageId: "m", sender: "S", senderEmail: "person@example.com",
                subject: "Hello", date: Date()
            )
        ])

        let info = try await db.latestUnsubscribeInfo(accountId: accountId, senderEmail: "person@example.com")
        XCTAssertNil(info)
    }
}
