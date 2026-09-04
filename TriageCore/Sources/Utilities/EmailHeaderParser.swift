import Foundation

/// Utility for parsing email headers (From, List-Unsubscribe, etc.)
public enum EmailHeaderParser {

    /// Parse "From" header into display name and email address
    /// Handles formats like:
    ///   "John Doe <john@example.com>"
    ///   "<john@example.com>"
    ///   "john@example.com"
    ///   "\"John Doe\" <john@example.com>"
    public static func parseSender(_ from: String) -> (name: String, email: String) {
        let trimmed = from.trimmingCharacters(in: .whitespaces)

        // Pattern: "Name <email>" or "<email>"
        if let angleStart = trimmed.lastIndex(of: "<"),
           let angleEnd = trimmed.lastIndex(of: ">"),
           angleStart < angleEnd {
            let email = String(trimmed[trimmed.index(after: angleStart)..<angleEnd])
                .trimmingCharacters(in: .whitespaces)
            var name = String(trimmed[..<angleStart])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                .trimmingCharacters(in: .whitespaces)

            if name.isEmpty {
                name = email.components(separatedBy: "@").first ?? email
            }
            return (name: name, email: email.lowercased())
        }

        // Plain email address
        let email = trimmed.lowercased()
        let name = email.components(separatedBy: "@").first ?? email
        return (name: name, email: email)
    }

    /// Parse List-Unsubscribe header into URLs and mailto addresses
    /// Format: "<mailto:unsub@example.com>, <https://example.com/unsub>"
    public static func parseListUnsubscribe(_ header: String) -> [UnsubscribeOption] {
        var options: [UnsubscribeOption] = []

        // Extract all <...> entries
        let pattern = "<([^>]+)>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return options
        }

        let matches = regex.matches(in: header, range: NSRange(header.startIndex..., in: header))
        for match in matches {
            if let range = Range(match.range(at: 1), in: header) {
                let value = String(header[range])
                if value.lowercased().hasPrefix("mailto:") {
                    let email = String(value.dropFirst(7))
                    options.append(.mailto(email))
                } else if value.lowercased().hasPrefix("http://") || value.lowercased().hasPrefix("https://") {
                    if let url = URL(string: value) {
                        options.append(.url(url))
                    }
                }
            }
        }

        return options
    }

    /// Parse an address-list header (`To`, `Cc`) into individual email addresses.
    ///
    /// Splits on commas that are outside quoted display names and outside angle
    /// brackets, so `"Doe, John" <j@x.com>, a@b.com` yields two addresses rather
    /// than three fragments.
    public static func parseAddressList(_ header: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var inAngles = false

        for character in header {
            switch character {
            case "\"":
                inQuotes.toggle()
                current.append(character)
            case "<" where !inQuotes:
                inAngles = true
                current.append(character)
            case ">" where !inQuotes:
                inAngles = false
                current.append(character)
            case "," where !inQuotes && !inAngles:
                fields.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        fields.append(current)

        return fields
            .map { parseSender($0).email }
            .filter { $0.contains("@") && !$0.hasPrefix("@") && !$0.hasSuffix("@") }
    }

    /// Extract domain from email address
    public static func extractDomain(_ email: String) -> String {
        let parts = email.lowercased().components(separatedBy: "@")
        return parts.count > 1 ? parts[1] : email
    }
}

/// Unsubscribe mechanism extracted from List-Unsubscribe header
public enum UnsubscribeOption: Sendable {
    case mailto(String)
    case url(URL)

    public var description: String {
        switch self {
        case .mailto(let email): return "Email: \(email)"
        case .url(let url): return "Web: \(url.absoluteString)"
        }
    }
}
