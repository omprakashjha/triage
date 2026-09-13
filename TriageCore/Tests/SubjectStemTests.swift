import XCTest
@testable import TriageCore

/// What a one-gesture decision covers.
///
/// These tests matter more than most: the stem decides how much mail a single drag applies to, and
/// getting it too wide means acting on mail the user never looked at.
final class SubjectStemTests: XCTestCase {

    private func stem(_ subject: String) -> String? { SubjectStem.stem(of: subject) }

    // MARK: - The case that motivated this

    func testDailyStatementLosesItsDate() {
        // The real correction from the user's mailbox. Matched one email; must now match the
        // family.
        XCTAssertEqual(
            stem("Daily Account Statement for 08/27/2026"),
            "daily account statement"
        )
        // Every issue of that mail must reduce to the SAME stem, which is the whole point.
        XCTAssertEqual(
            stem("Daily Account Statement for 09/13/2026"),
            stem("Daily Account Statement for 08/27/2026")
        )
    }

    func testASubjectWithNoVaryingPartIsUnchanged() {
        // Also from the user's mailbox, and correct as-is.
        XCTAssertEqual(stem("Earnings Notification"), "earnings notification")
        XCTAssertEqual(
            stem("Reminder to think before you click!"),
            "reminder to think before you click"
        )
    }

    func testInteriorStopwordsSurvive() {
        // Gutting the interior would leave a stem that reads as a different message.
        XCTAssertEqual(stem("Reminder to think before you click"),
                       "reminder to think before you click")
    }

    // MARK: - Date formats

    func testDateFormats() {
        XCTAssertEqual(stem("Statement 2026-08-27"), "statement")
        XCTAssertEqual(stem("Statement 27-08-2026"), "statement")
        XCTAssertEqual(stem("Statement 27.08.2026"), "statement")
        XCTAssertEqual(stem("Invoice for September 2026"), "invoice")
        XCTAssertEqual(stem("Invoice for 13 September 2026"), "invoice")
        XCTAssertEqual(stem("Uw factuur van 13 september 2026"), "factuur")
        XCTAssertEqual(stem("Report — Mon 13 Sept"), "report")
    }

    func testAMonthNameIsNotLeftBehindByItself() {
        // If the month survived, January's mail and February's would have different stems and the
        // decision would recur monthly — the exact failure this exists to prevent.
        XCTAssertEqual(stem("Overzicht januari 2026"), stem("Overzicht februari 2026"))
    }

    func testTimesAmountsAndReferences() {
        XCTAssertEqual(stem("Payment received: €1.234,56"), "payment received")
        XCTAssertEqual(stem("Payment received: 45 EUR"), "payment received")
        XCTAssertEqual(stem("Meeting at 14:30"), "meeting")
        XCTAssertEqual(stem("Invoice INV-000123"), "invoice")
        XCTAssertEqual(stem("Order #A1B2C3 shipped"), "order shipped")
        XCTAssertEqual(stem("Results for Q3 2026"), "results")
        XCTAssertEqual(stem("Week 37 overzicht"), "overzicht")
    }

    // MARK: - Refusing to over-generalize

    func testASubjectThatIsOnlyAVaryingPartYieldsNothing() {
        // "Falls back to the exact subject" is the caller's job; the extractor must say it found
        // no stem rather than return something meaninglessly short.
        XCTAssertNil(stem("08/27/2026"))
        XCTAssertNil(stem("#12345"))
        XCTAssertNil(stem("2026-08-27 14:30"))
    }

    func testASubjectOfOnlyStopwordsYieldsNothing() {
        XCTAssertNil(stem("Re: FW:"))
        XCTAssertNil(stem("your"))
    }

    func testAVeryShortRemainderYieldsNothing() {
        // A 2-character stem would apply a decision to mail the user never saw.
        XCTAssertNil(stem("Re: 12345 ok"))
    }

    // MARK: - decisionPattern contract

    func testDecisionPatternGeneralizesWhenItCan() {
        let result = SubjectStem.decisionPattern(for: "Daily Account Statement for 08/27/2026")
        XCTAssertEqual(result.pattern, "daily account statement")
        XCTAssertTrue(result.didGeneralize)
    }

    func testDecisionPatternFallsBackToTheExactSubject() {
        let result = SubjectStem.decisionPattern(for: "08/27/2026")
        XCTAssertEqual(result.pattern, "08/27/2026")
        XCTAssertFalse(result.didGeneralize, "no stem was found, so nothing was widened")
    }

    func testDecisionPatternReportsNoGeneralizationWhenNothingChanged() {
        // Nothing varied, so the pattern is the subject and the user should not be told it was
        // widened.
        let result = SubjectStem.decisionPattern(for: "Earnings Notification")
        XCTAssertEqual(result.pattern, "earnings notification")
        XCTAssertFalse(result.didGeneralize)
    }

    func testDecisionPatternAlwaysReturnsSomethingUsable() {
        // The caller writes this into a correction, so it can never be empty.
        for subject in ["", "   ", "#1", "Re:", "Daily Account Statement for 08/27/2026"] {
            let result = SubjectStem.decisionPattern(for: subject)
            XCTAssertEqual(result.pattern, result.pattern.trimmingCharacters(in: .whitespaces))
        }
    }

    // MARK: - The stem still identifies the mail

    func testStemsOfGenuinelyDifferentMailStayDifferent() {
        // Widening must not collapse distinct mail from one sender into a single decision.
        XCTAssertNotEqual(
            stem("Daily Account Statement for 08/27/2026"),
            stem("Earnings Notification")
        )
        XCTAssertNotEqual(
            stem("Uw factuur van 13 september 2026"),
            stem("Uw reisoverzicht van 13 september 2026")
        )
        XCTAssertNotEqual(stem("Order shipped"), stem("Order cancelled"))
    }
}
