import XCTest
@testable import TriageCore

final class EmailHeaderParserTests: XCTestCase {

    // MARK: - Sender Parsing

    func testParseStandardSender() {
        let result = EmailHeaderParser.parseSender("John Doe <john@example.com>")
        XCTAssertEqual(result.name, "John Doe")
        XCTAssertEqual(result.email, "john@example.com")
    }

    func testParseQuotedSender() {
        let result = EmailHeaderParser.parseSender("\"John Doe\" <john@example.com>")
        XCTAssertEqual(result.name, "John Doe")
        XCTAssertEqual(result.email, "john@example.com")
    }

    func testParseSenderWithoutName() {
        let result = EmailHeaderParser.parseSender("<john@example.com>")
        XCTAssertEqual(result.name, "john")
        XCTAssertEqual(result.email, "john@example.com")
    }

    func testParsePlainEmailAddress() {
        let result = EmailHeaderParser.parseSender("john@example.com")
        XCTAssertEqual(result.name, "john")
        XCTAssertEqual(result.email, "john@example.com")
    }

    func testParseEmailNormalizesToLowercase() {
        let result = EmailHeaderParser.parseSender("John <JOHN@Example.COM>")
        XCTAssertEqual(result.email, "john@example.com")
    }

    func testParseSenderWithSpecialChars() {
        let result = EmailHeaderParser.parseSender("O'Brien, Pat <pat.obrien@company.co.uk>")
        XCTAssertEqual(result.name, "O'Brien, Pat")
        XCTAssertEqual(result.email, "pat.obrien@company.co.uk")
    }

    // MARK: - List-Unsubscribe Parsing

    func testParseUnsubscribeMailto() {
        let header = "<mailto:unsubscribe@example.com>"
        let options = EmailHeaderParser.parseListUnsubscribe(header)
        XCTAssertEqual(options.count, 1)
        if case .mailto(let email) = options[0] {
            XCTAssertEqual(email, "unsubscribe@example.com")
        } else {
            XCTFail("Expected mailto option")
        }
    }

    func testParseUnsubscribeURL() {
        let header = "<https://example.com/unsubscribe?id=123>"
        let options = EmailHeaderParser.parseListUnsubscribe(header)
        XCTAssertEqual(options.count, 1)
        if case .url(let url) = options[0] {
            XCTAssertEqual(url.host, "example.com")
        } else {
            XCTFail("Expected URL option")
        }
    }

    func testParseUnsubscribeMultiple() {
        let header = "<mailto:unsub@example.com>, <https://example.com/unsub>"
        let options = EmailHeaderParser.parseListUnsubscribe(header)
        XCTAssertEqual(options.count, 2)
    }

    func testParseUnsubscribeEmpty() {
        let options = EmailHeaderParser.parseListUnsubscribe("")
        XCTAssertTrue(options.isEmpty)
    }

    // MARK: - Domain Extraction

    func testExtractDomain() {
        XCTAssertEqual(EmailHeaderParser.extractDomain("user@example.com"), "example.com")
        XCTAssertEqual(EmailHeaderParser.extractDomain("user@sub.example.co.uk"), "sub.example.co.uk")
        XCTAssertEqual(EmailHeaderParser.extractDomain("USER@EXAMPLE.COM"), "example.com")
    }
}
