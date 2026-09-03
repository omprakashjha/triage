import Foundation

/// App configuration constants.
/// Copy this file to Config/Secrets.swift and fill in your actual values.
/// Secrets.swift is gitignored.
enum AppConfig {
    /// Gmail OAuth2 Client ID from Google Cloud Console
    /// Create at: https://console.cloud.google.com/apis/credentials
    /// Type: Desktop application
    static let gmailClientId = "YOUR_CLIENT_ID.apps.googleusercontent.com"

    /// Custom URL scheme for OAuth callback
    /// Must match: com.googleusercontent.apps.YOUR_CLIENT_ID
    static let gmailRedirectURI = "com.triage.app:/oauth2redirect"

    /// Yahoo IMAP settings
    static let yahooIMAPHost = "imap.mail.yahoo.com"
    static let yahooIMAPPort: UInt16 = 993

    /// Feature flags
    static let premiumAIEnabled = false
}
