import Foundation

/// Gmail REST API client actor for fetching email metadata
public actor GmailAPIClient {
    private let baseURL = "https://gmail.googleapis.com/gmail/v1/users/me"
    private var tokens: OAuthTokens
    private let rateLimiter: RateLimiter
    private let retryPolicy: RetryPolicy
    private let session: URLSession

    public init(
        tokens: OAuthTokens,
        rateLimiter: RateLimiter,
        retryPolicy: RetryPolicy,
        session: URLSession = .shared
    ) {
        self.tokens = tokens
        self.rateLimiter = rateLimiter
        self.retryPolicy = retryPolicy
        self.session = session
    }

    /// Update tokens (e.g., after refresh)
    public func updateTokens(_ newTokens: OAuthTokens) {
        self.tokens = newTokens
    }

    // MARK: - Message List (Pagination)

    /// List message IDs with pagination. Returns (messageIds, nextPageToken, resultSizeEstimate)
    public func listMessages(
        query: String = "is:unread",
        pageToken: String? = nil,
        maxResults: Int = 500
    ) async throws -> MessageListResponse {
        var components = URLComponents(string: "\(baseURL)/messages")!
        var queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: String(maxResults)),
        ]
        if let pageToken {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        components.queryItems = queryItems

        let data = try await authenticatedRequest(url: components.url!)
        return try JSONDecoder().decode(MessageListResponse.self, from: data)
    }

    /// Fetch ALL message IDs matching a query (handles pagination automatically)
    public func listAllMessageIds(query: String = "is:unread") async throws -> [String] {
        var allIds: [String] = []
        var pageToken: String? = nil

        repeat {
            let response = try await listMessages(query: query, pageToken: pageToken)
            let ids = response.messages?.map(\.id) ?? []
            allIds.append(contentsOf: ids)
            pageToken = response.nextPageToken
        } while pageToken != nil

        return allIds
    }

    // MARK: - Message Metadata

    /// Fetch metadata for a single message
    public func getMessage(id: String) async throws -> GmailMessage {
        let url = URL(string: "\(baseURL)/messages/\(id)?format=metadata&metadataHeaders=From&metadataHeaders=Subject&metadataHeaders=Date&metadataHeaders=List-Unsubscribe&metadataHeaders=Reply-To")!

        let data = try await authenticatedRequest(url: url)
        return try JSONDecoder().decode(GmailMessage.self, from: data)
    }

    /// Batch fetch message metadata using Gmail batch API
    /// Processes in chunks of 100 (Gmail's batch limit)
    public nonisolated func batchGetMessages(ids: [String]) -> AsyncThrowingStream<[GmailMessage], Error> {
        AsyncThrowingStream { continuation in
            Task {
                let chunks = stride(from: 0, to: ids.count, by: 100).map {
                    Array(ids[$0..<min($0 + 100, ids.count)])
                }

                for chunk in chunks {
                    do {
                        let messages = try await self.fetchBatch(ids: chunk)
                        continuation.yield(messages)
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }
                continuation.finish()
            }
        }
    }

    /// Individual fetches with concurrency limit (simpler than multipart batch)
    private func fetchBatch(ids: [String]) async throws -> [GmailMessage] {
        try await withThrowingTaskGroup(of: GmailMessage.self) { group in
            // Limit concurrent requests to avoid overwhelming rate limiter
            let concurrencyLimit = 10
            var results: [GmailMessage] = []
            results.reserveCapacity(ids.count)

            var iterator = ids.makeIterator()
            var activeTasks = 0

            // Start initial batch
            for _ in 0..<min(concurrencyLimit, ids.count) {
                if let id = iterator.next() {
                    group.addTask { try await self.getMessage(id: id) }
                    activeTasks += 1
                }
            }

            // Process results and add new tasks as others complete
            while activeTasks > 0 {
                if let message = try await group.next() {
                    results.append(message)
                    activeTasks -= 1

                    // Start next task if available
                    if let id = iterator.next() {
                        group.addTask { try await self.getMessage(id: id) }
                        activeTasks += 1
                    }
                }
            }

            return results
        }
    }

    // MARK: - History (Incremental Sync)

    /// Fetch changes since a given historyId
    public func listHistory(
        startHistoryId: String,
        pageToken: String? = nil
    ) async throws -> HistoryListResponse {
        var components = URLComponents(string: "\(baseURL)/history")!
        var queryItems = [
            URLQueryItem(name: "startHistoryId", value: startHistoryId),
            URLQueryItem(name: "historyTypes", value: "messageAdded"),
            URLQueryItem(name: "historyTypes", value: "messageDeleted"),
            URLQueryItem(name: "historyTypes", value: "labelAdded"),
            URLQueryItem(name: "historyTypes", value: "labelRemoved"),
        ]
        if let pageToken {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        components.queryItems = queryItems

        let data = try await authenticatedRequest(url: components.url!)
        return try JSONDecoder().decode(HistoryListResponse.self, from: data)
    }

    /// Fetch all history records since a given historyId (handles pagination)
    public func listAllHistory(startHistoryId: String) async throws -> [HistoryRecord] {
        var allRecords: [HistoryRecord] = []
        var pageToken: String? = nil

        repeat {
            let response = try await listHistory(startHistoryId: startHistoryId, pageToken: pageToken)
            if let history = response.history {
                allRecords.append(contentsOf: history)
            }
            pageToken = response.nextPageToken
        } while pageToken != nil

        return allRecords
    }

    // MARK: - Message Actions

    /// Modify labels on a message (archive = remove INBOX label)
    public func modifyMessage(id: String, addLabels: [String] = [], removeLabels: [String] = []) async throws {
        let url = URL(string: "\(baseURL)/messages/\(id)/modify")!
        let body = ModifyRequest(addLabelIds: addLabels, removeLabelIds: removeLabels)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        _ = try await authenticatedRequest(request: request)
    }

    /// Move message to trash
    public func trashMessage(id: String) async throws {
        let url = URL(string: "\(baseURL)/messages/\(id)/trash")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try await authenticatedRequest(request: request)
    }

    /// Get user profile (for verifying connection and getting email address)
    public func getProfile() async throws -> GmailProfile {
        let url = URL(string: "\(baseURL)/profile")!
        let data = try await authenticatedRequest(url: url)
        return try JSONDecoder().decode(GmailProfile.self, from: data)
    }

    // MARK: - Authenticated Requests

    private func authenticatedRequest(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        return try await authenticatedRequest(request: request)
    }

    private func authenticatedRequest(request: URLRequest) async throws -> Data {
        var mutableRequest = request
        if mutableRequest.value(forHTTPHeaderField: "Authorization") == nil {
            mutableRequest.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        }
        let finalRequest = mutableRequest

        return try await withRetry(policy: retryPolicy, rateLimiter: rateLimiter) {
            let (data, response) = try await self.session.data(for: finalRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw APIError.httpError(statusCode: httpResponse.statusCode, body: body)
            }

            return data
        }
    }
}

// MARK: - Gmail API Response Models

public struct MessageListResponse: Decodable, Sendable {
    public let messages: [MessageRef]?
    public let nextPageToken: String?
    public let resultSizeEstimate: Int?

    public struct MessageRef: Decodable, Sendable {
        public let id: String
        public let threadId: String
    }
}

public struct GmailMessage: Decodable, Sendable {
    public let id: String
    public let threadId: String
    public let labelIds: [String]?
    public let snippet: String?
    public let payload: Payload?
    public let internalDate: String?
    public let historyId: String?

    public struct Payload: Decodable, Sendable {
        public let headers: [Header]?
    }

    public struct Header: Decodable, Sendable {
        public let name: String
        public let value: String
    }

    // MARK: - Convenience Accessors

    public var from: String? {
        payload?.headers?.first(where: { $0.name.lowercased() == "from" })?.value
    }

    public var subject: String? {
        payload?.headers?.first(where: { $0.name.lowercased() == "subject" })?.value
    }

    public var date: String? {
        payload?.headers?.first(where: { $0.name.lowercased() == "date" })?.value
    }

    public var listUnsubscribe: String? {
        payload?.headers?.first(where: { $0.name.lowercased() == "list-unsubscribe" })?.value
    }

    public var replyTo: String? {
        payload?.headers?.first(where: { $0.name.lowercased() == "reply-to" })?.value
    }

    public var isUnread: Bool {
        labelIds?.contains("UNREAD") ?? false
    }

    /// Parse the date string into a Date object
    public var parsedDate: Date? {
        // Try RFC 2822 format first
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        // Common date formats in email headers
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss z",
            "dd MMM yyyy HH:mm:ss z",
        ]

        if let dateStr = date {
            for format in formats {
                formatter.dateFormat = format
                if let parsed = formatter.date(from: dateStr) {
                    return parsed
                }
            }
        }

        // Fallback: use internalDate (milliseconds since epoch)
        if let internalDate, let millis = Int64(internalDate) {
            return Date(timeIntervalSince1970: TimeInterval(millis) / 1000.0)
        }

        return nil
    }

    /// Parse sender display name and email from "From" header
    public var parsedSender: (name: String, email: String)? {
        guard let from else { return nil }
        return EmailHeaderParser.parseSender(from)
    }
}

public struct GmailProfile: Decodable, Sendable {
    public let emailAddress: String
    public let messagesTotal: Int?
    public let threadsTotal: Int?
    public let historyId: String?
}

public struct HistoryListResponse: Decodable, Sendable {
    public let history: [HistoryRecord]?
    public let historyId: String?
    public let nextPageToken: String?
}

public struct HistoryRecord: Decodable, Sendable {
    public let id: String
    public let messagesAdded: [MessageAdded]?
    public let messagesDeleted: [MessageDeleted]?
    public let labelsAdded: [LabelModification]?
    public let labelsRemoved: [LabelModification]?

    public struct MessageAdded: Decodable, Sendable {
        public let message: MessageListResponse.MessageRef
    }

    public struct MessageDeleted: Decodable, Sendable {
        public let message: MessageListResponse.MessageRef
    }

    public struct LabelModification: Decodable, Sendable {
        public let message: MessageListResponse.MessageRef
        public let labelIds: [String]
    }
}

private struct ModifyRequest: Encodable {
    let addLabelIds: [String]
    let removeLabelIds: [String]
}
