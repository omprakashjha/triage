import SwiftUI

@main
struct TriageApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1000, height: 700)
    }
}
