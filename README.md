# Triage

A native macOS app to intelligently clean up Gmail and Yahoo email inboxes with 10K+ unread messages.

## Features

- **Gmail API** integration with OAuth2 (PKCE flow)
- **Yahoo IMAP** support with app passwords
- **Rule-based categorization** — newsletters, promotions, notifications, transactional, personal
- **Safety tiers** — SAFE (auto-actionable), REVIEW (needs approval), PROTECTED (never auto-deleted)
- **Batch operations** — archive, delete, label with undo support
- **Incremental sync** — only fetch new changes after initial scan
- **Rate limiting** — respects API quotas with exponential backoff
- **Premium AI** (opt-in) — LLM categorization for ambiguous emails

## Setup

### Prerequisites
- macOS 14+ (Sonoma)
- Xcode 15+
- A Google Cloud project with Gmail API enabled

### Gmail OAuth Setup

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create a new project (or use existing)
3. Enable the **Gmail API**
4. Go to **APIs & Services > Credentials**
5. Create **OAuth 2.0 Client ID** (type: macOS / Desktop)
6. Copy the Client ID
7. Create `Triage/Config/Secrets.swift`:

```swift
enum Secrets {
    static let gmailClientId = "YOUR_CLIENT_ID.apps.googleusercontent.com"
}
```

8. In Google Cloud Console, add your Google account as a **test user** under OAuth consent screen

### Yahoo Setup

1. Go to [Yahoo Account Security](https://login.yahoo.com/account/security)
2. Enable 2-Factor Authentication (if not already)
3. Generate an **App Password** for "Other App"
4. Use this app password when connecting Yahoo in the app

### Build & Run

```bash
# Resolve dependencies
cd /path/to/Triage
swift package resolve

# Build the core library
swift build

# Run tests
swift test

# Open in Xcode (for the full macOS app)
open Triage.xcodeproj
```

## Project Structure

```
Triage/
├── Package.swift              # SPM manifest for core library
├── TriageCore/                # Core library (testable, no UI)
│   ├── Sources/
│   │   ├── Models/            # Data models (GRDB records)
│   │   ├── Database/          # GRDB database + migrations
│   │   ├── Services/          # Gmail API, Auth, Rate Limiting
│   │   └── Utilities/         # Header parsing, helpers
│   └── Tests/                 # Unit tests
├── Triage/                    # macOS SwiftUI app
│   ├── App/                   # App entry point, AppState
│   ├── Views/                 # SwiftUI views
│   └── Config/                # Configuration (secrets gitignored)
└── README.md
```

## Architecture

- **GRDB** for local SQLite storage (fast bulk operations, WAL mode)
- **URLSession + async/await** for Gmail REST API
- **Actor-based concurrency** for thread safety
- **Protocol-based categorization engine** — rule engine (default) vs AI engine (premium)
- **AsyncThrowingStream** for progressive scan results

## Development

### Running Tests
```bash
swift test
```

### Adding a New Migration
Edit `AppDatabase.swift` and add a new migration block:
```swift
migrator.registerMigration("v2_new_feature") { db in
    // Schema changes here
}
```

## Roadmap

- [x] Phase 1: Foundation (GRDB, Gmail OAuth, API client, rate limiting)
- [ ] Phase 2: Yahoo IMAP + Rule-based categorization
- [ ] Phase 3: Action UI (preview, execute, undo)
- [ ] Phase 4: Premium AI module
- [ ] Phase 5: Polish (menu bar, scheduling, unsubscribe automation)
