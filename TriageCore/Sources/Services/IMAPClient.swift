import Foundation
import Network

/// IMAP client for Yahoo Mail using Apple's Network framework.
/// Supports app-password authentication and metadata-only fetching.
public actor IMAPClient {
    private let host: String
    private let port: UInt16
    private var connection: NWConnection?
    private var buffer: String = ""
    private var tagCounter: Int = 0
    private var isConnected: Bool = false

    public init(host: String = "imap.mail.yahoo.com", port: UInt16 = 993) {
        self.host = host
        self.port = port
    }

    // MARK: - Connection Lifecycle

    /// Connect and authenticate with the IMAP server
    public func connect(email: String, appPassword: String) async throws {
        let tlsParams = NWProtocolTLS.Options()
        let tcpParams = NWProtocolTCP.Options()
        tcpParams.connectionTimeout = 30

        let params = NWParameters(tls: tlsParams, tcp: tcpParams)
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )

        connection = NWConnection(to: endpoint, using: params)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: IMAPError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    continuation.resume(throwing: IMAPError.connectionCancelled)
                default:
                    break
                }
            }
            connection?.start(queue: .global(qos: .userInitiated))
        }

        isConnected = true

        // Read server greeting
        let greeting = try await readResponse()
        guard greeting.contains("OK") else {
            throw IMAPError.serverError("Bad greeting: \(greeting)")
        }

        // LOGIN
        let loginResponse = try await sendCommand("LOGIN \"\(email)\" \"\(appPassword)\"")
        guard loginResponse.contains("OK") else {
            throw IMAPError.authenticationFailed
        }
    }

    /// Disconnect from the server
    public func disconnect() async {
        if isConnected {
            _ = try? await sendCommand("LOGOUT")
        }
        connection?.cancel()
        connection = nil
        isConnected = false
    }

    // MARK: - Mailbox Operations

    /// Select a mailbox and return its message count
    public func selectMailbox(_ name: String = "INBOX") async throws -> MailboxInfo {
        let response = try await sendCommand("SELECT \"\(name)\"")

        var exists = 0
        var unseen = 0

        for line in response.components(separatedBy: "\r\n") {
            if line.contains("EXISTS") {
                exists = extractNumber(from: line) ?? 0
            }
            if line.contains("UNSEEN") {
                unseen = extractNumber(from: line) ?? 0
            }
        }

        return MailboxInfo(name: name, messageCount: exists, unseenCount: unseen)
    }

    /// Search for UIDs matching criteria
    public func searchUIDs(criteria: String = "UNSEEN") async throws -> [UInt32] {
        let response = try await sendCommand("UID SEARCH \(criteria)")

        // Parse "* SEARCH 1 2 3 4 5..." line
        for line in response.components(separatedBy: "\r\n") {
            if line.hasPrefix("* SEARCH") {
                let parts = line.dropFirst("* SEARCH".count)
                    .trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: " ")
                return parts.compactMap { UInt32($0) }
            }
        }

        return []
    }

    // MARK: - Fetch Operations

    /// Fetch envelope and headers for a set of UIDs (batch-friendly)
    public func fetchMetadata(uids: [UInt32]) async throws -> [IMAPMessageMetadata] {
        guard !uids.isEmpty else { return [] }

        let uidSet = uids.map(String.init).joined(separator: ",")
        let fetchItems = "(UID ENVELOPE BODY.PEEK[HEADER.FIELDS (List-Unsubscribe Reply-To)])"
        let response = try await sendCommand("UID FETCH \(uidSet) \(fetchItems)")

        return parseMessages(from: response)
    }

    /// Fetch metadata in batches with a delay between them
    public nonisolated func fetchAllMetadata(
        uids: [UInt32],
        batchSize: Int = 50,
        delayBetweenBatches: TimeInterval = 1.0
    ) -> AsyncThrowingStream<[IMAPMessageMetadata], Error> {
        AsyncThrowingStream { continuation in
            Task {
                let batches = stride(from: 0, to: uids.count, by: batchSize).map {
                    Array(uids[$0..<min($0 + batchSize, uids.count)])
                }

                for (index, batch) in batches.enumerated() {
                    do {
                        let messages = try await self.fetchMetadata(uids: batch)
                        continuation.yield(messages)

                        // Delay between batches (except the last one)
                        if index < batches.count - 1 {
                            try await Task.sleep(nanoseconds: UInt64(delayBetweenBatches * 1_000_000_000))
                        }
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Sent Folder Analysis (for contact detection)

    /// Move messages to a different mailbox (for archive/delete/undo)
    public func moveMessages(uids: String, toMailbox: String) async throws {
        let response = try await sendCommand("UID MOVE \(uids) \"\(toMailbox)\"")
        // Some servers don't support MOVE, fall back to COPY+DELETE
        if response.contains("BAD") || response.contains("NO") {
            _ = try await sendCommand("UID COPY \(uids) \"\(toMailbox)\"")
            _ = try await sendCommand("UID STORE \(uids) +FLAGS (\\Deleted)")
            _ = try await sendCommand("EXPUNGE")
        }
    }

    /// Fetch sender addresses from Sent folder to identify contacts
    public func fetchSentRecipients(limit: Int = 500) async throws -> Set<String> {
        // Yahoo's sent folder name
        let sentFolders = ["Sent", "INBOX.Sent", "Sent Messages", "Sent Items"]
        var selectedSent = false

        for folder in sentFolders {
            do {
                _ = try await selectMailbox(folder)
                selectedSent = true
                break
            } catch {
                continue
            }
        }

        guard selectedSent else { return [] }

        // Get recent message UIDs from sent folder
        let response = try await sendCommand("UID SEARCH ALL")
        var allUIDs: [UInt32] = []
        for line in response.components(separatedBy: "\r\n") {
            if line.hasPrefix("* SEARCH") {
                let parts = line.dropFirst("* SEARCH".count)
                    .trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: " ")
                allUIDs = parts.compactMap { UInt32($0) }
            }
        }

        // Take last N UIDs (most recent)
        let recentUIDs = Array(allUIDs.suffix(limit))
        guard !recentUIDs.isEmpty else { return [] }

        // Fetch To: headers
        let uidSet = recentUIDs.map(String.init).joined(separator: ",")
        let fetchResponse = try await sendCommand("UID FETCH \(uidSet) (BODY.PEEK[HEADER.FIELDS (To Cc)])")

        var recipients: Set<String> = []
        let emailRegex = try! NSRegularExpression(pattern: "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}")

        let lines = fetchResponse.components(separatedBy: "\r\n")
        for line in lines {
            let lowered = line.lowercased()
            if lowered.hasPrefix("to:") || lowered.hasPrefix("cc:") {
                let matches = emailRegex.matches(in: line, range: NSRange(line.startIndex..., in: line))
                for match in matches {
                    if let range = Range(match.range, in: line) {
                        recipients.insert(String(line[range]).lowercased())
                    }
                }
            }
        }

        return recipients
    }

    // MARK: - IMAP Protocol Implementation

    private func sendCommand(_ command: String) async throws -> String {
        guard isConnected, let connection else {
            throw IMAPError.notConnected
        }

        tagCounter += 1
        let tag = "T\(tagCounter)"
        let fullCommand = "\(tag) \(command)\r\n"

        // Send
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: fullCommand.data(using: .utf8),
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: IMAPError.sendFailed(error.localizedDescription))
                    } else {
                        continuation.resume()
                    }
                }
            )
        }

        // Read until we get our tagged response
        var fullResponse = ""
        while true {
            let chunk = try await readChunk()
            fullResponse += chunk

            // Check if we have our tagged response line
            if fullResponse.contains("\(tag) OK") ||
               fullResponse.contains("\(tag) NO") ||
               fullResponse.contains("\(tag) BAD") {
                break
            }
        }

        // Check for errors
        if fullResponse.contains("\(tag) NO") || fullResponse.contains("\(tag) BAD") {
            let errorLine = fullResponse.components(separatedBy: "\r\n")
                .first { $0.contains("\(tag) NO") || $0.contains("\(tag) BAD") } ?? "Unknown error"
            throw IMAPError.commandFailed(errorLine)
        }

        return fullResponse
    }

    private func readResponse() async throws -> String {
        try await readChunk()
    }

    private func readChunk() async throws -> String {
        guard let connection else {
            throw IMAPError.notConnected
        }

        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: IMAPError.readFailed(error.localizedDescription))
                    return
                }
                guard let data, let string = String(data: data, encoding: .utf8) else {
                    continuation.resume(returning: "")
                    return
                }
                continuation.resume(returning: string)
            }
        }
    }

    // MARK: - Parsing

    private func parseMessages(from response: String) -> [IMAPMessageMetadata] {
        var messages: [IMAPMessageMetadata] = []
        let sections = response.components(separatedBy: "* ")

        for section in sections {
            guard section.contains("FETCH") else { continue }

            let uid = extractUID(from: section)
            let envelope = parseEnvelope(from: section)
            let headers = parseHeaders(from: section)

            if let uid, let envelope {
                let metadata = IMAPMessageMetadata(
                    uid: uid,
                    sender: envelope.sender,
                    senderEmail: envelope.senderEmail,
                    subject: envelope.subject,
                    date: envelope.date,
                    hasListUnsubscribe: headers.listUnsubscribe != nil,
                    listUnsubscribeHeader: headers.listUnsubscribe,
                    replyTo: headers.replyTo
                )
                messages.append(metadata)
            }
        }

        return messages
    }

    private func extractUID(from section: String) -> UInt32? {
        let pattern = "UID (\\d+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: section, range: NSRange(section.startIndex..., in: section)),
              let range = Range(match.range(at: 1), in: section) else {
            return nil
        }
        return UInt32(section[range])
    }

    private func parseEnvelope(from section: String) -> EnvelopeData? {
        // IMAP ENVELOPE format:
        // ("date" "subject" ((from)) ((sender)) ((reply-to)) ((to)) ((cc)) ((bcc)) "in-reply-to" "message-id")
        guard let envelopeStart = section.range(of: "ENVELOPE (") else { return nil }
        let envelopeContent = String(section[envelopeStart.upperBound...])

        // Extract date (first quoted string)
        let date = extractQuotedString(from: envelopeContent, position: 0)

        // Extract subject (second quoted string)
        let subject = extractQuotedString(from: envelopeContent, position: 1)

        // Extract from address - look for the from field in envelope
        let (senderName, senderEmail) = extractFromAddress(from: envelopeContent)

        let parsedDate = parseIMAPDate(date ?? "")

        return EnvelopeData(
            sender: senderName ?? senderEmail ?? "Unknown",
            senderEmail: senderEmail ?? "unknown@unknown.com",
            subject: subject ?? "(No Subject)",
            date: parsedDate ?? Date()
        )
    }

    private func parseHeaders(from section: String) -> HeaderData {
        var listUnsubscribe: String? = nil
        var replyTo: String? = nil

        let lines = section.components(separatedBy: "\r\n")
        for (index, line) in lines.enumerated() {
            let lowered = line.lowercased().trimmingCharacters(in: .whitespaces)
            if lowered.hasPrefix("list-unsubscribe:") {
                listUnsubscribe = String(line.dropFirst("list-unsubscribe:".count)).trimmingCharacters(in: .whitespaces)
                // Check for continuation line
                if index + 1 < lines.count && (lines[index + 1].hasPrefix(" ") || lines[index + 1].hasPrefix("\t")) {
                    listUnsubscribe? += lines[index + 1].trimmingCharacters(in: .whitespaces)
                }
            }
            if lowered.hasPrefix("reply-to:") {
                replyTo = String(line.dropFirst("reply-to:".count)).trimmingCharacters(in: .whitespaces)
            }
        }

        return HeaderData(listUnsubscribe: listUnsubscribe, replyTo: replyTo)
    }

    private func extractQuotedString(from text: String, position: Int) -> String? {
        var count = 0
        var inQuote = false
        var current = ""
        var escaped = false

        for char in text {
            if escaped {
                current.append(char)
                escaped = false
                continue
            }
            if char == "\\" {
                escaped = true
                continue
            }
            if char == "\"" {
                if inQuote {
                    if count == position { return current }
                    count += 1
                    inQuote = false
                    current = ""
                } else {
                    inQuote = true
                }
            } else if inQuote {
                current.append(char)
            }
            // Handle NIL
            if !inQuote && text.dropFirst(text.distance(from: text.startIndex, to: text.firstIndex(of: char) ?? text.startIndex)).hasPrefix("NIL") {
                if count == position { return nil }
            }
        }
        return nil
    }

    private func extractFromAddress(from envelope: String) -> (name: String?, email: String?) {
        // From field in ENVELOPE is: ((personal-name NIL mailbox host))
        // We need to find the third set of parenthesized list (from address)
        // Simplified: look for email-like patterns after the subject
        let emailRegex = try! NSRegularExpression(pattern: "\"([^\"]+)\"\\s+NIL\\s+\"([^\"]+)\"\\s+\"([^\"]+)\"")
        let matches = emailRegex.matches(in: envelope, range: NSRange(envelope.startIndex..., in: envelope))

        if let match = matches.first {
            let name = match.range(at: 1).location != NSNotFound ?
                String(envelope[Range(match.range(at: 1), in: envelope)!]) : nil
            let mailbox = match.range(at: 2).location != NSNotFound ?
                String(envelope[Range(match.range(at: 2), in: envelope)!]) : nil
            let host = match.range(at: 3).location != NSNotFound ?
                String(envelope[Range(match.range(at: 3), in: envelope)!]) : nil

            if let mailbox, let host {
                return (name: name, email: "\(mailbox)@\(host)".lowercased())
            }
        }

        return (nil, nil)
    }

    private func parseIMAPDate(_ dateString: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss z",
            "dd-MMM-yyyy HH:mm:ss Z",
        ]
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: dateString) {
                return date
            }
        }
        return nil
    }

    private func extractNumber(from line: String) -> Int? {
        let pattern = "(\\d+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return Int(line[range])
    }
}

// MARK: - Supporting Types

public struct IMAPMessageMetadata: Sendable {
    public let uid: UInt32
    public let sender: String
    public let senderEmail: String
    public let subject: String
    public let date: Date
    public let hasListUnsubscribe: Bool
    public let listUnsubscribeHeader: String?
    public let replyTo: String?
}

public struct MailboxInfo: Sendable {
    public let name: String
    public let messageCount: Int
    public let unseenCount: Int
}

private struct EnvelopeData {
    let sender: String
    let senderEmail: String
    let subject: String
    let date: Date
}

private struct HeaderData {
    let listUnsubscribe: String?
    let replyTo: String?
}

public enum IMAPError: LocalizedError, Sendable {
    case connectionFailed(String)
    case connectionCancelled
    case notConnected
    case authenticationFailed
    case sendFailed(String)
    case readFailed(String)
    case commandFailed(String)
    case serverError(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .connectionCancelled: return "Connection was cancelled"
        case .notConnected: return "Not connected to server"
        case .authenticationFailed: return "Authentication failed. Check your app password."
        case .sendFailed(let msg): return "Send failed: \(msg)"
        case .readFailed(let msg): return "Read failed: \(msg)"
        case .commandFailed(let msg): return "Command failed: \(msg)"
        case .serverError(let msg): return "Server error: \(msg)"
        case .timeout: return "Connection timed out"
        }
    }
}
