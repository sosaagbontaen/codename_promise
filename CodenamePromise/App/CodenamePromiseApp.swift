import SwiftUI

@main
struct CodenamePromiseApp: App {
    init() {
        // A missing font falls back to Helvetica silently, which reads as a design choice
        // rather than a build problem. Fail loudly in debug instead.
        Type.assertAvailable()
        Chrome.apply()
    }

    @State private var services = AppServices()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(services)
                .task { await services.drainTranscriptions() }
        }
        .onChange(of: scenePhase) { _, phase in
            // The other half of the save discipline. The in-view debounce keeps typing from
            // thrashing the store; this closes the window that debounce opens, because
            // autosave is not a per-mutation durability guarantee. See ADR-001.
            switch phase {
            case .inactive, .background:
                services.flushOnBackground()
            case .active:
                // Connectivity may have returned while we were away.
                Task { await services.drainTranscriptions() }
            @unknown default:
                services.flushOnBackground()
            }
        }
    }
}

struct RootView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        switch services.state {
        case .ready:
            HomeView()
        case .failed(let message):
            StoreUnavailableView(message: message)
        }
    }
}

/// Shown when the store cannot be opened. Says the one thing the user actually needs to know.
struct StoreUnavailableView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("Couldn't open your journal")
                .font(.title2.weight(.semibold))
            Text("Your entries are still on disk. Nothing has been deleted.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
        }
        .padding(32)
    }
}
