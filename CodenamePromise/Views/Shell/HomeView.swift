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
    @State private var tab = Place.journal

    enum Place: Hashable { case journal, more }

    static let onboardedKey = "hasSeenOnboarding"

    var body: some View {
        TabView(selection: $tab) {
            JournalView()
                .tabItem { tabLabel("Journal", "book.closed", .journal) }
                .tag(Place.journal)
            SettingsView(showsDone: false)
                .tabItem { tabLabel("More", "ellipsis.circle", .more) }
                .tag(Place.more)
        }
        .tint(Brand.violet)
        .onChange(of: tab) { Haptics.switched() }
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

    /// Outline when it's not where you are, filled when it is. The tab bar would otherwise
    /// fill both, leaving colour as the only difference.
    private func tabLabel(_ title: String, _ symbol: String, _ which: Place) -> some View {
        Label(title, systemImage: tab == which ? symbol + ".fill" : symbol)
            .environment(\.symbolVariants, .none)
    }
}
