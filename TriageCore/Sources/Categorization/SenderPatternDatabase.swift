import Foundation

/// How strong the evidence behind a domain match is.
///
/// This matters because the *tier* (auto-actionable vs needs-approval) should follow
/// the quality of the evidence, not just the category. Matching `deals.brand.com`
/// is strong evidence of marketing; matching `mail.anything.com` is not — `mail.` and
/// `email.` are generic transport subdomains used by banks and utilities too.
public enum DomainMatchStrength: Sendable, Equatable {
    /// The domain (or its parent) is explicitly listed.
    case explicit
    /// A known bulk-marketing platform (Mailchimp, SendGrid, Klaviyo, ...).
    case platform
    /// Only a generic transport subdomain matched (`mail.`, `email.`). Weak.
    case generic
    /// No match.
    case none

    /// Whether this match is strong enough to justify an auto-actionable tier.
    public var isStrong: Bool {
        switch self {
        case .explicit, .platform: return true
        case .generic, .none: return false
        }
    }
}

/// Database of known sender patterns for rule-based email categorization.
/// Contains promotional domains, notification senders, social platforms, and transactional services.
public struct SenderPatternDatabase: Sendable {

    // MARK: - Domain Sets

    /// Known promotional/marketing email sending domains
    private let promotionalDomains: Set<String>

    /// Known notification service domains
    private let notificationDomains: Set<String>

    /// Social media platform domains
    private let socialDomains: Set<String>

    /// Transactional/financial domains
    private let transactionalDomains: Set<String>

    /// Marketing platform sending domains (Mailchimp, SendGrid, etc.)
    private let marketingPlatformDomains: Set<String>

    /// Domains that legitimately send BOTH promotional and transactional mail
    /// (Amazon sends "Deal of the day" and "Your order receipt" from the same domain).
    /// A domain alone cannot classify these — the subject has to break the tie.
    private let mixedDomains: Set<String>

    // MARK: - Default Instance

    public static let `default` = SenderPatternDatabase(
        promotionalDomains: Self.defaultPromotionalDomains,
        notificationDomains: Self.defaultNotificationDomains,
        socialDomains: Self.defaultSocialDomains,
        transactionalDomains: Self.defaultTransactionalDomains,
        marketingPlatformDomains: Self.defaultMarketingPlatformDomains,
        mixedDomains: Self.defaultMixedDomains
    )

    public init(
        promotionalDomains: Set<String>,
        notificationDomains: Set<String>,
        socialDomains: Set<String>,
        transactionalDomains: Set<String>,
        marketingPlatformDomains: Set<String>,
        mixedDomains: Set<String> = []
    ) {
        self.promotionalDomains = promotionalDomains
        self.notificationDomains = notificationDomains
        self.socialDomains = socialDomains
        self.transactionalDomains = transactionalDomains
        self.marketingPlatformDomains = marketingPlatformDomains
        self.mixedDomains = mixedDomains
    }

    // MARK: - Matching Methods

    /// Subdomains that genuinely indicate marketing intent.
    private static let discriminatingPromoSubdomains: Set<String> = [
        "promo", "offers", "deals", "marketing", "campaign", "newsletter",
    ]

    /// Subdomains that indicate only "this is bulk transport" — used by banks,
    /// utilities and insurers as much as by retailers. Weak evidence on their own.
    private static let genericTransportSubdomains: Set<String> = [
        "email", "mail",
    ]

    /// Classify how strongly a domain looks promotional.
    public func promotionalMatch(_ domain: String) -> DomainMatchStrength {
        let d = domain.lowercased()

        // Explicitly listed, or the registrable parent is (mail.walmart.com -> walmart.com)
        if promotionalDomains.contains(d) { return .explicit }
        if marketingPlatformDomains.contains(d) { return .platform }

        let parts = d.components(separatedBy: ".")
        if parts.count > 2 {
            let parent = parts.suffix(2).joined(separator: ".")
            if promotionalDomains.contains(parent) { return .explicit }
            if marketingPlatformDomains.contains(parent) { return .platform }

            let subdomain = parts[0]
            if Self.discriminatingPromoSubdomains.contains(subdomain) { return .explicit }
            if Self.genericTransportSubdomains.contains(subdomain) { return .generic }
        }

        return .none
    }

    /// Check if a domain is a known promotional sender.
    ///
    /// Kept as a boolean for call sites that only need "did anything match". Use
    /// ``promotionalMatch(_:)`` when the answer should influence the safety tier.
    public func isPromotionalDomain(_ domain: String) -> Bool {
        promotionalMatch(domain) != .none
    }

    /// Whether this sender is known to send both promotional and transactional mail,
    /// meaning the domain alone is not sufficient to categorize it.
    public func isMixedSender(domain: String) -> Bool {
        let d = domain.lowercased()
        if mixedDomains.contains(d) { return true }
        let parts = d.components(separatedBy: ".")
        if parts.count > 2 {
            return mixedDomains.contains(parts.suffix(2).joined(separator: "."))
        }
        return false
    }

    /// Check if a sender is a known notification service
    public func isNotificationSender(email: String, domain: String) -> Bool {
        let d = domain.lowercased()
        if notificationDomains.contains(d) { return true }

        // Check subdomain patterns
        let parts = d.components(separatedBy: ".")
        if parts.count > 2 {
            let subdomain = parts[0]
            let notifSubdomains = ["notify", "notification", "notifications", "alerts", "alert", "updates"]
            if notifSubdomains.contains(subdomain) { return true }
        }

        return false
    }

    /// Check if a domain belongs to a social media platform
    public func isSocialPlatform(domain: String) -> Bool {
        let d = domain.lowercased()
        if socialDomains.contains(d) { return true }

        // Check parent domain (e.g., mail.facebook.com → facebook.com)
        let parts = d.components(separatedBy: ".")
        if parts.count > 2 {
            let parentDomain = parts.suffix(2).joined(separator: ".")
            if socialDomains.contains(parentDomain) { return true }
        }

        return false
    }

    /// Check if a domain is a transactional sender
    public func isTransactionalDomain(_ domain: String) -> Bool {
        let d = domain.lowercased()
        if transactionalDomains.contains(d) { return true }

        let parts = d.components(separatedBy: ".")
        if parts.count > 2 {
            let parentDomain = parts.suffix(2).joined(separator: ".")
            if transactionalDomains.contains(parentDomain) { return true }
        }

        return false
    }

    // MARK: - Default Data

    private static let defaultPromotionalDomains: Set<String> = [
        // Retail
        "amazon.com", "ebay.com", "walmart.com", "target.com", "bestbuy.com",
        "costco.com", "macys.com", "nordstrom.com", "kohls.com", "gap.com",
        "nike.com", "adidas.com", "zara.com", "hm.com", "uniqlo.com",
        "etsy.com", "wayfair.com", "overstock.com", "wish.com",

        // Food & Delivery
        "ubereats.com", "doordash.com", "grubhub.com", "postmates.com",
        "instacart.com", "seamless.com",

        // Travel
        "booking.com", "expedia.com", "hotels.com", "airbnb.com",
        "kayak.com", "tripadvisor.com", "hopper.com",

        // Deal sites
        "groupon.com", "retailmenot.com", "slickdeals.com",
        "honey.com", "rakuten.com",
    ]

    private static let defaultNotificationDomains: Set<String> = [
        // Cloud / SaaS notifications
        "github.com", "gitlab.com", "bitbucket.org",
        "atlassian.com", "jira.com", "confluence.com",
        "slack.com", "notion.so", "asana.com", "trello.com",
        "monday.com", "clickup.com", "linear.app",

        // Developer tools
        "vercel.com", "netlify.com", "heroku.com",
        "aws.amazon.com", "cloud.google.com", "azure.com",
        "sentry.io", "datadog.com", "pagerduty.com",

        // Productivity
        "todoist.com", "evernote.com", "dropbox.com",
        "box.com", "onedrive.com",

        // Security / Auth
        "1password.com", "lastpass.com", "authy.com",
    ]

    private static let defaultSocialDomains: Set<String> = [
        // Social networks
        "facebook.com", "facebookmail.com", "instagram.com",
        "twitter.com", "x.com",
        "linkedin.com", "linkedinmail.com",
        "pinterest.com", "reddit.com", "tumblr.com",
        "tiktok.com", "snapchat.com",

        // Messaging
        "whatsapp.com", "telegram.org", "signal.org",
        "discord.com", "discordapp.com",

        // Media / Content
        "youtube.com", "twitch.tv", "medium.com",
        "substack.com", "quora.com",

        // Dating
        "tinder.com", "bumble.com", "hinge.co",

        // Community
        "meetup.com", "nextdoor.com", "eventbrite.com",
    ]

    private static let defaultTransactionalDomains: Set<String> = [
        // Banking / Finance
        "chase.com", "bankofamerica.com", "wellsfargo.com",
        "citi.com", "capitalone.com", "americanexpress.com",
        "discover.com", "paypal.com", "venmo.com",
        "squarecash.com", "zelle.com", "stripe.com",
        "wise.com", "revolut.com",

        // Insurance
        "geico.com", "statefarm.com", "progressive.com",
        "allstate.com", "usaa.com",

        // Utilities
        "comcast.com", "xfinity.com", "att.com", "verizon.com",
        "tmobile.com", "sprint.com",

        // Subscriptions
        "apple.com", "google.com", "microsoft.com",
        "netflix.com", "spotify.com", "hulu.com",
        "disneyplus.com", "hbomax.com", "amazon.com",

        // Healthcare
        "myhealth.com", "zocdoc.com", "onemedical.com",
    ]

    /// Senders that ship both marketing and transactional mail from one domain.
    /// Listed here so the engine disambiguates by subject instead of guessing from the domain.
    /// These deliberately also appear in the promotional/transactional sets so that the
    /// boolean domain checks keep reporting a match.
    private static let defaultMixedDomains: Set<String> = [
        "amazon.com",
        "apple.com",
        "google.com",
        "microsoft.com",
        "paypal.com",
        "ebay.com",
        "booking.com",
        "airbnb.com",
        "uber.com",
        "ubereats.com",
        "doordash.com",
        "instacart.com",
        "netflix.com",
        "spotify.com",
        "etsy.com",
        "walmart.com",
        "target.com",
        "bestbuy.com",
        "costco.com",
    ]

    private static let defaultMarketingPlatformDomains: Set<String> = [
        // Email marketing platforms (sender domains)
        "mailchimp.com", "mail.mailchimp.com",
        "sendgrid.net", "sendgrid.com",
        "mailgun.org", "mailgun.com",
        "constantcontact.com", "ctctmail.com",
        "hubspot.com", "hubspotmail.net",
        "klaviyo.com",
        "braze.com", "appboy.com",
        "iterable.com",
        "sailthru.com",
        "sendinblue.com", "brevo.com",
        "campaign-archive.com",  // Mailchimp archive
        "list-manage.com",       // Mailchimp
        "createsend.com",        // Campaign Monitor
        "cmail19.com", "cmail20.com",  // Campaign Monitor variants
        "exacttarget.com",       // Salesforce Marketing Cloud
        "sfmc.co",
        "pardot.com",            // Salesforce Pardot
        "marketo.com",
        "eloqua.com",            // Oracle Eloqua
        "responsys.net",         // Oracle Responsys
        "amazonses.com",         // Amazon SES (often marketing)
        "mandrillapp.com",       // Mailchimp transactional
    ]
}
