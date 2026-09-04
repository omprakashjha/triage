import Foundation
import Smithy
import TriageCore

// MARK: - JSONValue <-> Smithy.Document

extension JSONValue {

    /// Maps onto Smithy's document type by conforming a private wrapper, rather than
    /// reaching for the `@_spi(SmithyDocumentImpl)` concrete types — those are not
    /// public API and would break on an SDK bump.
    var smithyDocument: Smithy.Document {
        Smithy.Document(Wrapper(value: self))
    }

    init(smithy document: Smithy.Document) {
        self = JSONValue(smithyDocument: document)
    }

    private init(smithyDocument document: any SmithyDocument) {
        switch document.type {
        case .map, .structure:
            if let map = try? document.asStringMap() {
                self = .object(map.mapValues { JSONValue(smithyDocument: $0) })
            } else {
                self = .null
            }
        case .list, .set:
            if let list = try? document.asList() {
                self = .array(list.map { JSONValue(smithyDocument: $0) })
            } else {
                self = .null
            }
        case .string, .enum:
            self = (try? document.asString()).map(JSONValue.string) ?? .null
        case .boolean:
            self = (try? document.asBoolean()).map(JSONValue.bool) ?? .null
        case .byte, .short, .integer, .long, .intEnum, .bigInteger:
            self = (try? document.asInteger()).map(JSONValue.integer) ?? .null
        case .float, .double, .bigDecimal:
            self = (try? document.asDouble()).map(JSONValue.number) ?? .null
        default:
            self = .null
        }
    }

    /// Minimal `SmithyDocument` conformance. The protocol's default methods throw for
    /// mismatched types, so only the accessors that can actually apply are given.
    private struct Wrapper: SmithyDocument {
        let value: JSONValue

        var type: Smithy.ShapeType {
            switch value {
            case .string:  .string
            case .number:  .double
            case .integer: .integer
            case .bool:    .boolean
            case .array:   .list
            case .object:  .map
            case .null:    .document
            }
        }

        func asString() throws -> String {
            guard let string = value.stringValue else {
                throw DocumentError.typeMismatch("expected string, got \(value)")
            }
            return string
        }

        func asBoolean() throws -> Bool {
            guard let bool = value.boolValue else {
                throw DocumentError.typeMismatch("expected boolean, got \(value)")
            }
            return bool
        }

        func asInteger() throws -> Int {
            guard let int = value.intValue else {
                throw DocumentError.typeMismatch("expected integer, got \(value)")
            }
            return int
        }

        func asDouble() throws -> Double {
            guard let double = value.doubleValue else {
                throw DocumentError.typeMismatch("expected double, got \(value)")
            }
            return double
        }

        func asList() throws -> [any SmithyDocument] {
            guard let array = value.arrayValue else {
                throw DocumentError.typeMismatch("expected list, got \(value)")
            }
            return array.map { Wrapper(value: $0) }
        }

        func asStringMap() throws -> [String: any SmithyDocument] {
            guard let object = value.objectValue else {
                throw DocumentError.typeMismatch("expected map, got \(value)")
            }
            return object.mapValues { Wrapper(value: $0) }
        }

        func size() -> Int {
            switch value {
            case .array(let items):  items.count
            case .object(let items): items.count
            default:                 -1
            }
        }

        func getMember(_ memberName: String) throws -> (any SmithyDocument)? {
            value.objectValue?[memberName].map { Wrapper(value: $0) }
        }
    }
}
