import XCTest
@testable import TriageCore

/// `JSONValue` is the boundary type between the pure schema/parsing code and the
/// SDK-linked transport, so its accessors have to be exact — a wrong nil here would
/// silently drop a field out of a verdict.
final class JSONValueTests: XCTestCase {

    func testAccessorsReturnNilForWrongType() {
        XCTAssertNil(JSONValue.string("x").boolValue)
        XCTAssertNil(JSONValue.bool(true).stringValue)
        XCTAssertNil(JSONValue.string("5").intValue)
        XCTAssertNil(JSONValue.integer(5).arrayValue)
        XCTAssertNil(JSONValue.null.objectValue)
    }

    func testNumericAccessorsBridgeBothWays() {
        // The model may return 1 or 1.0 for the same field.
        XCTAssertEqual(JSONValue.integer(3).doubleValue, 3.0)
        XCTAssertEqual(JSONValue.number(3.7).intValue, 3)
        XCTAssertEqual(JSONValue.number(0.92).doubleValue, 0.92)
    }

    func testSubscriptTraversal() {
        let value = JSONValue.object([
            "outer": .object(["inner": .array([.string("found")])])
        ])
        XCTAssertEqual(value["outer"]?["inner"]?.arrayValue?.first?.stringValue, "found")
        XCTAssertNil(value["missing"]?["inner"])
    }

    func testLiteralConstruction() {
        let value: JSONValue = .object([
            "name": "triage",
            "count": 3,
            "ratio": 0.5,
            "enabled": true,
            "tags": .array(["a", "b"]),
        ])
        XCTAssertEqual(value["name"]?.stringValue, "triage")
        XCTAssertEqual(value["count"]?.intValue, 3)
        XCTAssertEqual(value["ratio"]?.doubleValue, 0.5)
        XCTAssertEqual(value["enabled"]?.boolValue, true)
        XCTAssertEqual(value["tags"]?.arrayValue?.count, 2)
    }

    func testCodableRoundTrip() throws {
        let original: JSONValue = .object([
            "verdicts": .array([
                .object([
                    "senderEmail": "a@b.com",
                    "confidence": 0.85,
                    "mustKeep": false,
                    "nested": .object(["deep": .array([1, 2, 3])]),
                    "nothing": .null,
                ])
            ])
        ])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

        XCTAssertEqual(decoded["verdicts"]?.arrayValue?.count, 1)
        let entry = decoded["verdicts"]?.arrayValue?[0]
        XCTAssertEqual(entry?["senderEmail"]?.stringValue, "a@b.com")
        XCTAssertEqual(entry?["confidence"]?.doubleValue, 0.85)
        XCTAssertEqual(entry?["mustKeep"]?.boolValue, false)
        XCTAssertEqual(entry?["nested"]?["deep"]?.arrayValue?.count, 3)
        XCTAssertEqual(entry?["nothing"], JSONValue.null)
    }

    func testSchemaIsSerializable() throws {
        // The schema crosses into the SDK as a document; if it cannot serialize here it
        // will not survive that trip either.
        let data = try JSONEncoder().encode(SenderClassificationPrompt.outputSchema)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded["type"]?.stringValue, "object")
        XCTAssertNotNil(decoded["properties"]?["verdicts"])
    }
}
