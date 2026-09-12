import SwiftUI
import TriageCore

/// Reads back what the app actually did.
///
/// Exists because the sidebar defect is only observable while running, in an app I cannot see,
/// and four rounds of reasoning about it produced four wrong answers. The transcript is
/// copyable so it can be pasted back verbatim — a paraphrased symptom is what has cost most of
/// those rounds.
struct DiagnosticsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if !appState.diagnostics.isEnabled {
                off
            } else if appState.diagnostics.entries.isEmpty {
                waiting
            } else {
                transcript
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Diagnostics")
                .font(.title2.weight(.semibold))

            Toggle("Record what the app does", isOn: Binding(
                get: { appState.diagnostics.isEnabled },
                set: { on in
                    appState.diagnostics.isEnabled = on
                    if on {
                        appState.diagnostics.clear()
                        // The watchdog is what turns "the UI seems to freeze" into a measured
                        // number, by detecting when the main run loop could not fire on time.
                        appState.diagnostics.startWatchdog()
                        appState.diagnostics.log("session", "recording started")
                    } else {
                        appState.diagnostics.stopWatchdog()
                    }
                }
            ))

            // Off by default on purpose: this records view-body evaluations, which are frequent
            // enough that always-on instrumentation would change the timing it is measuring.
            Text("Off by default — it records every view update, so leaving it on affects the timings it measures.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if appState.diagnostics.isEnabled {
                HStack(spacing: 10) {
                    Button("Copy transcript") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            appState.diagnostics.transcript, forType: .string
                        )
                    }
                    Button("Clear") { appState.diagnostics.clear() }
                        .buttonStyle(.borderless)
                    Spacer()
                    Text("\(appState.diagnostics.entries.count) entries")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
    }

    private var off: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Recording is off")
                .font(.headline)
            Text("Turn it on, then reproduce the problem: quit and relaunch the app, click Review, and come back here. Copy the transcript and send it over.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var waiting: some View {
        Text("Recording. Reproduce the problem, then come back.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcript: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(appState.diagnostics.entries) { entry in
                    Text(entry.line)
                        .font(.system(.caption2, design: .monospaced))
                        // A stall and an unexpected state change are what this is for, so they
                        // are the two things that must be findable by eye in a long transcript.
                        .foregroundStyle(colour(for: entry))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func colour(for entry: DiagnosticLog.Entry) -> Color {
        if entry.category == "STALL" { return .red }
        if entry.category == "accounts" { return .orange }
        if entry.sincePrevious > 500 { return .red }
        return .secondary
    }
}
