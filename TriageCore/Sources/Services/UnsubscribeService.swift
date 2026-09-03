import Foundation

/// Executes unsubscribe requests from a `List-Unsubscribe` header.
///
/// This is the only feature that reduces FUTURE mail rather than cleaning up past
/// mail, which is why it matters disproportionately to how much work the app saves.
///
/// Only ever invoked from an explicit user action. Automatic unsubscribing is
/// deliberately not offered: a POST to a URL supplied by an email is a request to a
/// third party, and confirming a live address to a bad actor is a real cost.
public actor UnsubscribeService {

    public enum Outcome: Sendable, Equatable {
        /// RFC 8058 one-click POST succeeded.
        case oneClickSucceeded
        /// The sender offers a web page that needs a human (a form, a login, a confirm button).
        case needsBrowser(URL)
        /// Only a mailto: option — the caller must send a message from the account.
        case needsEmail(String)
        /// No usable mechanism in the header.
        case unavailable
    }

    public enum UnsubscribeError: LocalizedError, Sendable {
        case httpFailure(statusCode: Int)
        case transport(String)

        public var errorDescription: String? {
            switch self {
            case .httpFailure(let code):
                return "The sender's unsubscribe endpoint returned HTTP \(code)."
            case .transport(let message):
                return "Could not reach the unsubscribe endpoint: \(message)"
            }
        }
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Attempt to unsubscribe using the strongest mechanism the header offers.
    ///
    /// `supportsOneClick` must come from the presence of `List-Unsubscribe-Post`
    /// (RFC 8058). Posting to a URL that did NOT advertise one-click support is not
    /// safe: for those senders the URL may be a GET-only confirmation page, and a
    /// blind POST can either fail or perform something unintended.
    public func unsubscribe(
        header: String,
        supportsOneClick: Bool
    ) async throws -> Outcome {
        let options = EmailHeaderParser.parseListUnsubscribe(header)

        let httpsURL: URL? = options.compactMap { option -> URL? in
            if case .url(let url) = option { return url }
            return nil
        }.first

        let mailto: String? = options.compactMap { option -> String? in
            if case .mailto(let address) = option { return address }
            return nil
        }.first

        if supportsOneClick, let url = httpsURL {
            try await postOneClick(to: url)
            return .oneClickSucceeded
        }

        if let url = httpsURL {
            return .needsBrowser(url)
        }

        if let mailto {
            return .needsEmail(mailto)
        }

        return .unavailable
    }

    /// The RFC 8058 one-click request: a POST with a fixed form body.
    private func postOneClick(to url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "List-Unsubscribe=One-Click".data(using: .utf8)
        request.timeoutInterval = 20

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw UnsubscribeError.transport("no HTTP response")
            }
            guard (200...299).contains(http.statusCode) else {
                throw UnsubscribeError.httpFailure(statusCode: http.statusCode)
            }
        } catch let error as UnsubscribeError {
            throw error
        } catch {
            throw UnsubscribeError.transport(error.localizedDescription)
        }
    }
}

/// Record of an unsubscribe attempt, so the result can be verified on a later scan.
///
/// An unsubscribe that silently did nothing is indistinguishable from one that worked
/// until more mail arrives — keeping the attempt date is what makes that checkable.
public struct UnsubscribeAttempt: Identifiable, Sendable {
    public var id: String { senderEmail }

    public let senderEmail: String
    public let attemptedAt: Date
    public let method: String
    public let succeeded: Bool
    public let note: String?

    public init(
        senderEmail: String,
        attemptedAt: Date = Date(),
        method: String,
        succeeded: Bool,
        note: String? = nil
    ) {
        self.senderEmail = senderEmail
        self.attemptedAt = attemptedAt
        self.method = method
        self.succeeded = succeeded
        self.note = note
    }

    /// Mail arriving after this date means the unsubscribe did not take effect.
    public func wasIgnored(latestMailDate: Date?) -> Bool {
        guard succeeded, let latestMailDate else { return false }
        // Allow a grace period — senders are permitted time to process the request.
        return latestMailDate > attemptedAt.addingTimeInterval(10 * 86400)
    }
}
