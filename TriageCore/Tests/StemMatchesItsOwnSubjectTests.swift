import XCTest
@testable import TriageCore

/// Does a stem actually MATCH the email it came from?
///
/// Generating a pattern and matching a pattern are two different code paths, and nothing checked
/// that they agree. If they disagree the decision is saved, the recategorization runs, and nothing
/// happens — indistinguishable from a broken gesture.
///
/// The first version of this test passed while the bug was live, because every case in it removed
/// something from an EDGE of the subject. Substring matching survives that and cannot survive an
/// interior removal, so the corpus below deliberately includes subjects whose removed part sits in
/// the middle. A property test is only as good as the shape of its inputs.
final class StemMatchesItsOwnSubjectTests: XCTestCase {

    /// Real subjects from the user's mailbox.
    private let realSubjects = [
        // Interior removals — the case the original corpus missed.
        "Duurzame Dinsdag: groen eropuit met de trein",
        "Vrijdag 13 maart: werkzaamheden op jouw route",
        "Invoice 12345 for September services",
        "Report for week 37 is ready",
        // Punctuation inside the kept phrase.
        "Let op: Werkzaamheden Noordstad Centrum - Zuidstad Centrum/Westdorp/Oosthaven-Zuid",
        "Ontdek Spoor-wandelroutes van station naar station",
        "Nieuw bij Spoor: in- en uitchecken met betaalpas, creditcard of mobiel",
        // Trailing removals — the easy case, kept as a regression guard.
        "Daily Account Statement for 08/27/2026",
        "Uw factuur van 13 september 2026",
        "Payment received: €1.234,56",
        // Nothing to remove at all.
        "Samen eropuit deze zomervakantie",
        "Reminder to think before you click!",
        "Earnings Notification",
    ]

    func testEveryStemMatchesTheSubjectItWasDerivedFrom() {
        // The invariant the whole feature rests on. A pattern that cannot match its own source email
        // decides nothing at all, silently.
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

    func testAGoldenLabelMatchesTheSameMailItsCorrectionDid() {
        // Labels are promoted from corrections, so the two matchers must agree or every accuracy
        // measurement this app makes is understated.
        for subject in realSubjects {
            let pattern = SubjectStem.decisionPattern(for: subject).pattern
            let label = GoldenLabel(
                accountId: 1,
                senderEmail: "sender@example.com",
                subjectPattern: pattern,
                expectedCategory: .notification,
                disposition: .disposable
            )
            XCTAssertTrue(
                label.matches(senderEmail: "sender@example.com", subject: subject),
                "label “\(pattern)” does not match its own subject “\(subject)”"
            )
        }
    }

    func testAHandTypedLiteralStillMatches() {
        // The other kind of pattern: a word the user typed, which must keep matching literally.
        let correction = UserCorrection(
            accountId: 1,
            senderEmail: "waterbedrijf@example.com",
            subjectPattern: "jaarafrekening",
            category: .transactional,
            mustKeep: true
        )
        XCTAssertTrue(correction.matches(
            senderEmail: "waterbedrijf@example.com",
            subject: "Uw jaarafrekening van 2026 staat klaar"
        ))
        XCTAssertFalse(correction.matches(
            senderEmail: "waterbedrijf@example.com",
            subject: "Uw factuur staat klaar"
        ))
    }

    func testAHandTypedPatternWithPunctuationMatches() {
        // Typed with a hyphen, stored with a hyphen, and the subject has one too — normalization is
        // applied to both sides so this cannot depend on the user matching the punctuation exactly.
        let correction = UserCorrection(
            accountId: 1,
            senderEmail: "info@email.spoorwegen.example",
            subjectPattern: "Spoor-wandelroutes",
            category: .promotion,
            mustKeep: false
        )
        XCTAssertTrue(correction.matches(
            senderEmail: "info@email.spoorwegen.example",
            subject: "Ontdek Spoor wandelroutes van station naar station"
        ))
    }

    func testDistinctMailIsStillNotSweptUp() {
        // Widening the matcher must not make unrelated mail from the same sender match.
        let pattern = SubjectStem.decisionPattern(
            for: "Duurzame Dinsdag: groen eropuit met de trein"
        ).pattern
        let correction = UserCorrection(
            accountId: 1,
            senderEmail: "info@email.spoorwegen.example",
            subjectPattern: pattern,
            category: .promotion,
            mustKeep: false
        )
        XCTAssertFalse(correction.matches(
            senderEmail: "info@email.spoorwegen.example",
            subject: "Uw factuur van 13 september 2026"
        ))
        XCTAssertFalse(correction.matches(
            senderEmail: "info@email.spoorwegen.example",
            subject: "Samen eropuit deze zomervakantie"
        ))
    }
}
