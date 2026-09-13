import Foundation

/// Reduces a subject line to the part that recurs, so one gesture covers a recurring family.
///
/// Motivated by a real correction in the user's own mailbox:
///
///     subjectPattern = "daily account statement for 08/27/2026"   mustKeep = 1
///
/// That pattern matches exactly one email. The next day's statement is a different subject, so the
/// same decision would have to be made again every single day, forever — which defeats the point
/// of deciding by subject at all. The stem is `daily account statement`, and that covers the
/// family.
///
/// The approach is to remove what VARIES between issues of the same recurring mail and keep what
/// identifies it. Anything containing a digit is treated as varying: dates, times, amounts, order
/// and invoice numbers, reference codes, statement periods. That is a blunt rule and deliberately
/// so — a token with a digit in it is almost always an identifier rather than a description, and
/// the alternative is an unbounded catalogue of date formats across two languages.
///
/// This WIDENS what a decision covers, so it is conservative at the edges: if stripping leaves
/// nothing meaningful behind, the caller is given the exact subject instead of a pattern that
/// would match far more mail than the user was looking at.
public enum SubjectStem {

    /// The single normalization both generating and matching a pattern must use.
    ///
    /// This exists because they disagreed, and the consequences were invisible. A stem is built by
    /// replacing punctuation with spaces, so
    ///
    ///     "Let op: Werkzaamheden Noordstad Centrum - Zuidstad Centrum/Westdorp/Oosthaven-Zuid"
    ///
    /// yields `let op werkzaamheden noordstad centrum zuidstad centrum westdorp oosthaven zuid`, which is
    /// NOT a substring of the original — the colon, the dash and the slashes are gone. Matching was
    /// a plain `subject.contains(pattern)` against the raw subject, so the pattern could not match
    /// the very email it was derived from. The correction saved, the recategorization ran, and
    /// nothing moved.
    ///
    /// It failed only for subjects with punctuation INSIDE the kept phrase, which is why it looked
    /// intermittent rather than broken: mail like "Samen eropuit deze zomervakantie" worked and
    /// anything with a colon or a hyphen silently did not.
    ///
    /// Applied to BOTH sides, so a hand-typed pattern keeps working whether or not the user types
    /// the punctuation.
    public static func normalizedForMatching(_ text: String) -> String {
        let lowered = text.lowercased()
        let despunctuated = lowered.replacingOccurrences(
            of: #"[\p{P}\p{S}]+"#,
            with: " ",
            options: [.regularExpression]
        )
        return despunctuated
            .split(whereSeparator: { $0 == " " || $0.isNewline || $0 == "\t" })
            .joined(separator: " ")
    }

    /// Whether a stored pattern applies to a subject, under one consistent normalization.
    ///
    /// Two forms of pattern have to work here, and they need different comparisons.
    ///
    /// A HAND-TYPED pattern ("jaarafrekening") is a literal the user expects to find in the subject,
    /// so it is matched against the normalized subject.
    ///
    /// A GENERATED stem has had varying tokens removed, and not only from the ends. In
    ///
    ///     "Duurzame Dinsdag: groen eropuit met de trein"
    ///
    /// the weekday is removed from the MIDDLE, leaving `duurzame groen eropuit met de trein`, which
    /// is not a contiguous substring of the subject and so can never be found in it. Comparing it
    /// against the subject's OWN stem works, because that had the same tokens removed.
    ///
    /// Accepting either form is deliberate: it keeps typed patterns matching literally while making
    /// generated ones match reliably, and neither can be expressed in terms of the other.
    public static func pattern(_ pattern: String, matches subject: String) -> Bool {
        let normalizedPattern = normalizedForMatching(pattern)
        guard !normalizedPattern.isEmpty else { return true }
        if normalizedForMatching(subject).contains(normalizedPattern) { return true }
        if let subjectStem = stem(of: subject),
           normalizedForMatching(subjectStem).contains(normalizedPattern) { return true }
        return false
    }

    /// Words that carry no identifying signal, so a stem consisting only of these is not a stem.
    /// Both languages, because this mailbox is Dutch and English.
    private static let stopwords: Set<String> = [
        "re", "fw", "fwd", "the", "a", "an", "of", "for", "on", "at", "in", "to", "from",
        "your", "you", "our", "and", "is", "are", "was", "with", "by", "no", "nr",
        "de", "het", "een", "van", "voor", "op", "en", "uw", "je", "jouw", "met", "aan",
        "bij", "naar", "over", "dit", "deze", "die", "dat", "er", "te",
    ]

    /// Patterns for the parts of a subject that change between issues of the same mail.
    ///
    /// Ordered most specific first: a date must be consumed as a date before its components can
    /// be picked off individually as bare numbers, or `27 September 2026` would leave `September`
    /// behind and the stem would still be unique to one month.
    private static let varyingPatterns: [String] = [
        // Month names with an adjacent number, either order. English and Dutch.
        #"\b(?:jan|feb|mar|mrt|apr|may|mei|jun|jul|aug|sep|sept|oct|okt|nov|dec|january|february|march|april|june|july|august|september|october|november|december|januari|februari|maart|juni|juli|augustus|oktober)[a-z]*\.?\s*\d{1,4}\b"#,
        #"\b\d{1,2}(?:st|nd|rd|th|e|de|ste)?\s+(?:jan|feb|mar|mrt|apr|may|mei|jun|jul|aug|sep|sept|oct|okt|nov|dec|january|february|march|april|june|july|august|september|october|november|december|januari|februari|maart|juni|juli|augustus|oktober)[a-z]*\.?\b"#,
        // Weekday names, which vary on daily mail and identify nothing.
        #"\b(?:mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun|monday|tuesday|wednesday|thursday|friday|saturday|sunday|maandag|dinsdag|woensdag|donderdag|vrijdag|zaterdag|zondag)\b"#,
        // Clock times.
        #"\b\d{1,2}:\d{2}(?::\d{2})?\s*(?:am|pm|uur)?\b"#,
        // Currency amounts, symbol before or code after.
        #"[€$£¥]\s?\d[\d.,]*"#,
        #"\b\d[\d.,]*\s?(?:eur|usd|gbp|euro|dollar)\b"#,
        // Quarters, weeks and similar period markers.
        #"\bq[1-4]\b"#,
        #"\b(?:week|wk|kwartaal|quarter|maand|month)\s*\d{1,2}\b"#,
        // The catch-all: any token containing a digit. Dates in any remaining format, order
        // numbers, invoice references, percentages, statement periods, tracking codes.
        #"\S*\d\S*"#,
    ]

    /// The recurring part of a subject, or `nil` when nothing meaningful survives.
    ///
    /// Returning `nil` rather than a very short string is deliberate: the caller must fall back to
    /// the exact subject, because a two-character pattern would silently apply a decision to mail
    /// the user never saw.
    public static func stem(of subject: String) -> String? {
        var working = subject.lowercased()

        for pattern in varyingPatterns {
            working = working.replacingOccurrences(
                of: pattern,
                with: " ",
                options: [.regularExpression]
            )
        }

        // Punctuation that only held the removed parts together, e.g. the dash in
        // "statement — 08/2026" or the parentheses in "invoice (12345)".
        working = working.replacingOccurrences(
            of: #"[\p{P}\p{S}]+"#,
            with: " ",
            options: [.regularExpression]
        )

        var tokens = working
            .split(whereSeparator: { $0 == " " || $0.isNewline || $0 == "\t" })
            .map(String.init)
            .filter { !$0.isEmpty }

        // Trim stopwords from the ENDS only. An interior one is part of the phrase — "reminder to
        // think before you click" is a real recurring subject and gutting its interior would leave
        // a stem that reads as a different message.
        while let first = tokens.first, stopwords.contains(first) { tokens.removeFirst() }
        while let last = tokens.last, stopwords.contains(last) { tokens.removeLast() }

        let candidate = tokens.joined(separator: " ")

        // Must retain real signal. Four characters and at least one non-stopword token, or the
        // caller gets nothing and uses the exact subject.
        guard candidate.count >= 4,
              tokens.contains(where: { !stopwords.contains($0) && $0.count >= 2 })
        else { return nil }

        return candidate
    }

    /// The pattern a one-gesture decision should use for this subject.
    ///
    /// Always returns something usable: the stem when one can be extracted, the trimmed exact
    /// subject otherwise. `didGeneralize` lets the caller tell the user which happened, because
    /// the two cover very different amounts of mail.
    public static func decisionPattern(for subject: String) -> (pattern: String, didGeneralize: Bool) {
        let exact = subject
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard let stem = stem(of: subject), stem != exact else {
            return (exact, false)
        }
        return (stem, true)
    }
}
