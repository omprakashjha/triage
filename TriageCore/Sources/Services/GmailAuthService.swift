import Foundation
import AuthenticationServices
import CryptoKit
import KeychainAccess

/// Handles Gmail OAuth2 authentication flow using ASWebAuthenticationSession
public final class GmailAuthService: NSObject, @unchecked Sendable {
    private let clientId: String
    private let redirectURI: String
    private let callbackScheme: String
    private let keychain: Keychain

    private static let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenURL = "https://oauth2.googleapis.com/token"
    private static let scopes = [
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.readonly"
    ]

    /// In-process token cache, so one scan does not re-authorise against the Keychain
    /// for every access. Guarded by a lock because this type is `@unchecked Sendable`
    /// and `getValidTokens()` is reachable off the main actor.
    private var cachedTokens: OAuthTokens?
    private let cacheLock = NSLock()

    public init(clientId: String) {
        self.clientId = clientId
        // iOS-type OAuth clients use reversed client ID as the URL scheme
        let reversedClientId = clientId.components(separatedBy: ".").reversed().joined(separator: ".")
        self.callbackScheme = reversedClientId
        self.redirectURI = "\(reversedClientId):/oauthredirect"
        self.keychain = Keychain(service: "com.triage.app")
            .accessibility(.whenUnlockedThisDeviceOnly)
        super.init()
    }

    // MARK: - Public API

    /// Start OAuth flow - shows native sign-in sheet
    @MainActor
    public func authenticate() async throws -> OAuthTokens {
        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)
        let state = UUID().uuidString

        let authorizationURL = buildAuthURL(codeChallenge: codeChallenge, state: state)
        let callbackURL = try await performWebAuth(url: authorizationURL)
        let code = try extractAuthCode(from: callbackURL, expectedState: state)
        let tokens = try await exchangeCodeForTokens(code: code, codeVerifier: codeVerifier)

        // Initial sign-in must always write: there is nothing stored yet.
        try saveTokens(tokens, forcePersist: true)
        return tokens
    }

    /// Get valid tokens, refreshing if expired
    public func getValidTokens() async throws -> OAuthTokens {
        guard let tokens = loadTokens() else {
            throw GmailAuthError.notAuthenticated
        }

        if tokens.isExpired {
            let refreshed = try await refreshAccessToken(refreshToken: tokens.refreshToken)
            try saveTokens(refreshed)
            return refreshed
        }

        return tokens
    }

    /// Check if we have stored credentials
    public var isAuthenticated: Bool {
        loadTokens() != nil
    }

    /// Clear stored credentials (sign out)
    public func signOut() throws {
        cacheLock.lock()
        cachedTokens = nil
        cacheLock.unlock()

        try? keychain.remove(Self.tokensKey)
        // Legacy items, in case sign-out happens before a migration ever ran.
        try? keychain.remove(Self.legacyAccessTokenKey)
        try? keychain.remove(Self.legacyRefreshTokenKey)
        try? keychain.remove(Self.legacyExpiresAtKey)
    }

    // MARK: - OAuth Flow Implementation

    @MainActor
    private func performWebAuth(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: GmailAuthError.authSessionFailed(error.localizedDescription))
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: GmailAuthError.noCallbackURL)
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = self
            session.start()
        }
    }

    private func buildAuthURL(codeChallenge: String, state: String) -> URL {
        var components = URLComponents(string: Self.authURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return components.url!
    }

    private func extractAuthCode(from url: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else {
            throw GmailAuthError.invalidCallbackURL
        }

        // Check for error
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw GmailAuthError.authDenied(error)
        }

        // Verify state
        guard let state = items.first(where: { $0.name == "state" })?.value,
              state == expectedState else {
            throw GmailAuthError.stateMismatch
        }

        // Extract code
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw GmailAuthError.noAuthCode
        }

        return code
    }

    private func exchangeCodeForTokens(code: String, codeVerifier: String) async throws -> OAuthTokens {
        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id": clientId,
            "code": code,
            "code_verifier": codeVerifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ]
        request.httpBody = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GmailAuthError.tokenExchangeFailed(errorBody)
        }

        let tokenResponse = try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
        return OAuthTokens(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken ?? "",
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn)),
            tokenType: tokenResponse.tokenType,
            scope: tokenResponse.scope
        )
    }

    private func refreshAccessToken(refreshToken: String) async throws -> OAuthTokens {
        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id": clientId,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        request.httpBody = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GmailAuthError.tokenRefreshFailed(errorBody)
        }

        let tokenResponse = try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
        return OAuthTokens(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken ?? refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn)),
            tokenType: tokenResponse.tokenType,
            scope: tokenResponse.scope
        )
    }

    // MARK: - PKCE

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Keychain Storage

    /// All tokens live in ONE Keychain item, as JSON.
    ///
    /// This matters for more than tidiness. Every Keychain access is a separate
    /// authorisation check, so the previous design — three items read individually and
    /// written individually — produced SIX password prompts for a single scan with an
    /// expired token (three reads, then three writes after the refresh). One item is
    /// one prompt.
    private static let tokensKey = "gmail_oauth_tokens"

    /// Superseded by ``tokensKey``. Read once during migration, then deleted.
    private static let legacyAccessTokenKey = "gmail_access_token"
    private static let legacyRefreshTokenKey = "gmail_refresh_token"
    private static let legacyExpiresAtKey = "gmail_expires_at"

    /// Update the tokens, persisting only when the durable half actually changed.
    ///
    /// The access token expires in about an hour and is re-derivable from the refresh
    /// token, so writing it back to the Keychain after every refresh costs one
    /// authorisation — a password prompt — and buys nothing. The refresh token is the
    /// only part worth storing, and it rarely changes.
    ///
    /// `forcePersist` is for the two cases where we must write regardless: the initial
    /// sign-in, and the migration off the legacy layout.
    private func saveTokens(_ tokens: OAuthTokens, forcePersist: Bool = false) throws {
        cacheLock.lock()
        let previousRefresh = cachedTokens?.refreshToken
        cachedTokens = tokens
        cacheLock.unlock()

        // No cache means we cannot know what is stored, so write to be safe.
        let refreshTokenChanged = previousRefresh == nil || previousRefresh != tokens.refreshToken
        guard forcePersist || refreshTokenChanged else { return }

        let data = try JSONEncoder().encode(tokens)
        try keychain.set(data, key: Self.tokensKey)
    }

    /// Load tokens, preferring the in-process cache.
    ///
    /// The cache exists because a single scan asks for tokens more than once, and
    /// without it each ask is another prompt. It holds for the process lifetime only —
    /// tokens are never written anywhere except the Keychain.
    private func loadTokens() -> OAuthTokens? {
        cacheLock.lock()
        if let cached = cachedTokens {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        if let data = try? keychain.getData(Self.tokensKey),
           let tokens = try? JSONDecoder().decode(OAuthTokens.self, from: data) {
            cacheLock.lock()
            cachedTokens = tokens
            cacheLock.unlock()
            return tokens
        }

        // Nothing under the combined key — fall back to the three legacy items and
        // collapse them. Costs three prompts exactly once, then never again.
        return migrateLegacyTokens()
    }

    /// One-time migration from the three-item layout to the single item.
    private func migrateLegacyTokens() -> OAuthTokens? {
        guard let accessToken = try? keychain.get(Self.legacyAccessTokenKey),
              let refreshToken = try? keychain.get(Self.legacyRefreshTokenKey),
              let expiresAtString = try? keychain.get(Self.legacyExpiresAtKey),
              let expiresAt = ISO8601DateFormatter().date(from: expiresAtString) else {
            return nil
        }

        let tokens = OAuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt
        )

        // Write the combined item first, so a failure here cannot lose the tokens.
        try? saveTokens(tokens, forcePersist: true)
        try? keychain.remove(Self.legacyAccessTokenKey)
        try? keychain.remove(Self.legacyRefreshTokenKey)
        try? keychain.remove(Self.legacyExpiresAtKey)

        return tokens
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension GmailAuthService: ASWebAuthenticationPresentationContextProviding {
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        ASPresentationAnchor()
    }
}

// MARK: - Supporting Types

private struct GoogleTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let tokenType: String
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case scope
    }
}

public enum GmailAuthError: LocalizedError {
    case notAuthenticated
    case authSessionFailed(String)
    case noCallbackURL
    case invalidCallbackURL
    case authDenied(String)
    case stateMismatch
    case noAuthCode
    case tokenExchangeFailed(String)
    case tokenRefreshFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not authenticated. Please sign in."
        case .authSessionFailed(let msg): return "Auth session failed: \(msg)"
        case .noCallbackURL: return "No callback URL received."
        case .invalidCallbackURL: return "Invalid callback URL."
        case .authDenied(let reason): return "Authentication denied: \(reason)"
        case .stateMismatch: return "State mismatch — possible CSRF attack."
        case .noAuthCode: return "No authorization code in callback."
        case .tokenExchangeFailed(let msg): return "Token exchange failed: \(msg)"
        case .tokenRefreshFailed(let msg): return "Token refresh failed: \(msg)"
        }
    }
}
