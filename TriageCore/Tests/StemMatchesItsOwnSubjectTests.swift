import XCTest
@testable import TriageCore

/// Does a stem actually MATCH the email it came from?
///
/// Generating a pattern and matching a pattern are two different code paths, and nothing until now
/// checked that they agree. If they disagree the decision is saved, the recategorization runs, and
/// nothing happens — which is indistinguishable from a broken gesture.
final class StemMatchesItsOwnSubjectTests: XCTestCase {

    /// Real subjects from the user's mailbox, punctuation included.
    private let realSubjects = [
        "Let op: Werkzaamheden Almere Centrum - Lelystad Centrum/Weesp/Naarden-Bussum",
        "Ontdek NS-wandelroutes van station naar station",
        "Samen eropuit deze zomervakantie",
        "Daily Activity Statement for 08/27/2026",
        "Reminder to think before you click!",
        "Uw factuur van 13 september 2026",
        "Payment received: €1.234,56",
    ]

    func testEveryStemMatchesTheSubjectItWasDerivedFrom() {
        // The invariant the whole feature rests on. A pattern that cannot match its own source
        // email decides nothing at all.
        for subject in realSubjects {
            let pattern = SubjectStem.decisionPattern(for: subject).pattern
            let correction = UserCorrection(
                accountId: 1,
                senderEmail: "sender@example.com",
                subjectPattern: pattern,
                category: .notification,
                mustKeep: false
            )
            XCTAssertTrue(
                correction.matches(senderEmail: "sender@example.com", subject: subject),
                "stem “\(pattern)” does not match its own subject “\(subject)”"
            )
        }
    }
}
