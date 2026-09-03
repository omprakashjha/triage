import Foundation
import GRDB

/// A standing decision about a sender, applied automatically on every future scan.
///
/// This is what turns triage from a one-time sweep into maintenance: deciding
/// "always archive this newsletter" once means the next scan needs no decision at all.
public struct SenderRule: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable {
    public var id: Int64?
    public var accountId: Int64
    /// Either a full address (`news@shop.com`) or a bare domain (`shop.com`).
    /// Interpreted by ``scope``.
    public var pattern: String
    public var scope: RuleScope
    public var action: EmailAction
    /// When set, the rule only applies to mail older than this many days.
    public var minAgeDays: Int?
    public var isEnabled: Bool
    public var createdAt: Date

    public init(
        id: Int64? = nil,
        accountId: Int64,
        pattern: String,
        scope: RuleScope = .address,
        action: EmailAction,
        minAgeDays: Int? = nil,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.accountId = accountId
        self.pattern = pattern.lowercased()
        self.scope = scope
        self.action = action
        self.minAgeDays = minAgeDays
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }

    public enum Columns: String, ColumnExpression {
        case id, accountId, pattern, scope, action, minAgeDays, isEnabled, createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Whether this rule governs the given email.
    public func matches(_ email: EmailMetadata, now: Date = Date()) -> Bool {
        guard isEnabled else { return false }

        let sender = email.senderEmail.lowercased()
        let matchesSender: Bool
        switch scope {
        case .address:
            matchesSender = sender == pattern
        case .domain:
            let domain = EmailHeaderParser.extractDomain(sender)
            // Match the domain itself or any subdomain of it.
            matchesSender = domain == pattern || domain.hasSuffix("." + pattern)
        }
        guard matchesSender else { return false }

        if let minAgeDays {
            let cutoff = now.addingTimeInterval(-Double(minAgeDays) * 86400)
            guard email.date < cutoff else { return false }
        }

        return true
    }
}

public enum RuleScope: String, Codable, CaseIterable, Sendable {
    /// Exactly this address.
    case address
    /// This domain and its subdomains.
    case domain

    public var displayName: String {
        switch self {
        case .address: return "This address"
        case .domain: return "Whole domain"
        }
    }
}
