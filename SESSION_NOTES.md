# Triage - Development Session Notes

## Last Updated: 2026-07-10

## What's Built (Complete)

### Phase 1 - Foundation ✅
- GRDB local SQLite database with migrations
- Gmail OAuth2 (PKCE flow) using iOS-type client
- GmailAPIClient with async/await
- RateLimiter (45 req/sec) with exponential backoff
- KeychainAccess for token storage

### Phase 2 - Providers & Categorization ✅
- Yahoo IMAP client (IMAPClient, YahooService)
- Rule-based categorization engine (priority: contacts → unsubscribe header → sender patterns → subject keywords → automated sender → fallback)
- SenderPatternDatabase (promotional, notification, social, transactional domains)
- ContactDetector

### Phase 3 - Action UI ✅
- ActionPlanner generates plans from categorized emails
- BatchExecutor executes plans via Gmail API
- ActionPlanView with approve/reject per item
- CategoryBreakdownView with drill-down into emails
- Safety tiers: Safe (auto-action), Review (needs approval), Protected (never touch)

### Phase 3.5 - Find Similar & Execute Flow ✅ (added 2026-07-10)
- "Find Similar" button on each email → finds all with same subject
- Preview sheet with select all/deselect + bulk Delete/Archive
- "Pending Actions" panel in Inbox Overview (auto-refreshes every 2s)
- "Execute on Gmail" button that actually calls Gmail API
- After execution: removes deleted emails from local DB, refreshes stats
- Delete/re-add account via right-click context menu in sidebar

## OAuth Setup
- Client type: **iOS** (in Google Cloud Console)
- Bundle ID: `com.triage.app`
- Client ID stored in: `Triage/Config/Secrets.swift` (gitignored)
- Uses reversed client ID as callback scheme with ASWebAuthenticationSession
- Test users must be added in OAuth consent screen

## How to Run
```bash
cd ~/Development/Triage
swift run TriageApp
```
Or open `Triage.xcodeproj` in Xcode (may have package resolution issues — SPM run is more reliable).

## Known Issues
- Timer-based refresh on PendingActionsView (every 2s) — should be event-driven
- Archived emails stay in local DB after execution (only deleted ones removed)
- App runs unsigned — macOS Keychain prompts on first access each launch
- Xcode .xcodeproj may not resolve the local SPM package correctly — use `swift run` instead

## What's Next (Phase 4+)
- Expand "Find Similar" matching: by sender, domain, not just subject
- Premium AI categorization (LLM for ambiguous emails)
- Menu bar mode
- Scheduled scans
- Unsubscribe automation
- Polish: proper code signing, app icon, Dock integration

## Project Structure
```
Triage/
├── Package.swift                    # SPM manifest (TriageCore lib + TriageApp executable)
├── Triage.xcodeproj/               # Xcode project (alternative to swift run)
├── TriageCore/Sources/
│   ├── Models/                     # EmailAccount, EmailMetadata, OAuthTokens, ActionLog, ScanProgress
│   ├── Database/AppDatabase.swift  # GRDB database + all queries
│   ├── Services/                   # GmailAuthService, GmailAPIClient, GmailService, YahooService, IMAPClient, RateLimiter
│   ├── Categorization/            # RuleBasedEngine, SenderPatternDatabase, ContactDetector
│   ├── Actions/                   # ActionPlanner, BatchExecutor
│   └── Utilities/                 # EmailHeaderParser
├── TriageCore/Tests/              # Unit tests (all passing)
├── Triage/
│   ├── App/                       # TriageApp.swift, AppState.swift
│   ├── Views/                     # ContentView, CategoryBreakdownView, ActionPlanView
│   └── Config/                    # AppConfig.swift, Secrets.swift (gitignored)
└── README.md
```
