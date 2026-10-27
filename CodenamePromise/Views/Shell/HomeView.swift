import CodenamePromiseCore
import SwiftUI

/// The journal, and settings.
///
/// Record used to be a tab of its own, a whole screen whose only job was a button. Recording
/// happens inside an entry, and dumping happens from the + on the journal.
struct HomeView: View {
    @Environment(AppServices.self) private var services

    /// Shown once, on the first launch, and never again unless Settings asks for it.
    @AppStorage(Self.onboardedKey) private var hasOnboarded = false
    @State private var showingOnboarding = false

    static let onboardedKey = "hasSeenOnboarding"

    var body: some View {
        TabView {
            JournalView()
                .tabItem { Label("Journal", systemImage: "calendar") }
            SettingsView(showsDone: false)
                .tabItem { Label("More", systemImage: "line.3.horizontal") }
        }
        .tint(Brand.violet)
        // Full screen and not dismissible by swipe: it is three sentences and one button,
        // and someone who flicks it away by accident has learned none of them.
        .fullScreenCover(isPresented: $showingOnboarding) {
            OnboardingView {
                hasOnboarded = true
                showingOnboarding = false
            }
        }
        .task { if !hasOnboarded { showingOnboarding = true } }
        // At the root, so an import brought back after the app was reclaimed comes up over
        // whatever is showing rather than waiting somewhere nobody is looking.
        .sheet(
            isPresented: Binding(
                get: { services.imports?.isPresented ?? false },
                set: { services.imports?.isPresented = $0 }
            ),
        ) {
            if let imports = services.imports, let store = services.store {
                PhotoImportView(imports: imports, store: store)
                    .tint(Brand.violet)
            }
        }
    }
}
