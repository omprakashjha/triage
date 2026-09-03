import Foundation

/// OAuth2 tokens for Gmail authentication
public struct OAuthTokens: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var tokenType: String
    public var scope: String?

    public init(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        tokenType: String = "Bearer",
        scope: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.tokenType = tokenType
        self.scope = scope
    }

    /// Whether the access token has expired (with 60s buffer)
    public var isExpired: Bool {
        Date().addingTimeInterval(60) >= expiresAt
    }
}
