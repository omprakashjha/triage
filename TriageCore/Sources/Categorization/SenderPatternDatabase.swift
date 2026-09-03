import Foundation

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

    // MARK: - Default Instance

    public static let `default` = SenderPatternDatabase(
        promotionalDomains: Self.defaultPromotionalDomains,
        notificationDomains: Self.defaultNotificationDomains,
        socialDomains: Self.defaultSocialDomains,
        transactionalDomains: Self.defaultTransactionalDomains,
        marketingPlatformDomains: Self.defaultMarketingPlatformDomains
    )

    public init(
        promotionalDomains: Set<String>,
        notificationDomains: Set<String>,
        socialDomains: Set<String>,
        transactionalDomains: Set<String>,
        marketingPlatformDomains: Set<String>
    ) {
        self.promotionalDomains = promotionalDomains
        self.notificationDomains = notificationDomains
        self.socialDomains = socialDomains
        self.transactionalDomains = transactionalDomains
        self.marketingPlatformDomains = marketingPlatformDomains
    }

    // MARK: - Matching Methods

    /// Check if a domain is a known promotional sender
    public func isPromotionalDomain(_ domain: String) -> Bool {
        let d = domain.lowercased()
        if promotionalDomains.contains(d) { return true }

        // Check if sent via marketing platform
        if marketingPlatformDomains.contains(d) { return true }

        // Check subdomain patterns (e.g., email.store.com, promo.brand.com)
        let parts = d.components(separatedBy: ".")
        if parts.count > 2 {
            let subdomain = parts[0]
            let promoSubdomains = ["email", "mail", "promo", "offers", "deals", "marketing", "campaign", "newsletter"]
            if promoSubdomains.contains(subdomain) { return true }
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
