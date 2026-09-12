import Foundation
import Combine

/// A timestamped, in-memory record of what the app actually did.
///
/// Built because four rounds of reasoning about why the sidebar empties produced four wrong
/// answers. The information needed to settle it — whether `accounts` is empty at that moment,
/// which state changed in what order, and whether the main thread stalled — exists only at
/// runtime in an app I cannot see.
///
/// Deliberately NOT `print`. In a bundled app launched by the Finder, stdout is a pipe nothing
/// drains, so once its buffer fills a write blocks; doing that from view updates or the database
/// queue would corrupt the very timing being measured. A ring buffer costs nothing and cannot
/// stall its caller.
@MainActor
final class DiagnosticLog: ObservableObject {
    struct Entry: Identifiable {
        let id = UUID()
        let at: Date
        /// Milliseconds since the previous entry. The gaps are the point: a multi-second gap
        /// between two adjacent entries IS a stall, and no amount of reasoning substitutes for
        /// seeing one.
        let sincePrevious: Double
        let category: String
        let message: String

        var line: String {
            let stamp = Entry.formatter.string(from: at)
            let gap = sincePrevious >= 1 ? String(format: " (+%.0fms)", sincePrevious) : ""
            return "\(stamp)\(gap) [\(category)] \(message)"
        }

        private static let formatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f
        }()
    }

    /// Bounded so a long session cannot grow it without limit.
    private static let capacity = 400

    @Published private(set) var entries: [Entry] = []
    /// Off by default. Instrumentation that is always on is instrumentation that changes what it
    /// measures, and this records view-body evaluations, which are extremely frequent.
    @Published var isEnabled = false

    private var lastAt: Date?
    private var watchdog: Timer?
    private var watchdogExpected: Date?

    func log(_ category: String, _ message: String) {
        guard isEnabled else { return }
        let now = Date()
        let gap = lastAt.map { now.timeIntervalSince($0) * 1000 } ?? 0
        lastAt = now
        entries.append(Entry(at: now, sincePrevious: gap, category: category, message: message))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    func clear() {
        entries.removeAll()
        lastAt = nil
    }

    var transcript: String {
        entries.map(\.line).joined(separator: "\n")
    }

    /// Detect main-thread stalls directly instead of inferring them.
    ///
    /// A timer scheduled on the main run loop can only fire when the main thread is free, so a
    /// fire that arrives late by N milliseconds proves the main thread was blocked for about N.
    /// This is the difference between "the UI probably stalls" — which is what I have been
    /// asserting — and a measured number.
    func startWatchdog(interval: TimeInterval = 0.25) {
        stopWatchdog()
        watchdogExpected = Date().addingTimeInterval(interval)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = Date()
                if let expected = self.watchdogExpected {
                    let lateBy = now.timeIntervalSince(expected) * 1000
                    // Only report meaningful lateness; run-loop jitter is tens of ms.
                    if lateBy > 250 {
                        self.log("STALL", String(format: "main thread blocked ~%.0fms", lateBy))
                    }
                }
                self.watchdogExpected = now.addingTimeInterval(interval)
            }
        }
        // .common so it keeps firing while a menu or a List selection is tracking, which is
        // exactly when the reported freeze happens.
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
        watchdogExpected = nil
    }
}
