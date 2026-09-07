import CodenamePromiseCore
import SwiftUI

/// Three places, with Record in the middle.
///
/// Centre because it is the thumb's home and the thing you open the app to do. Capture is
/// not a mode you enter from a list, and it is not a tray you load either: the product is
/// one button, and the middle of the screen is where it belongs.
///
/// This replaced a staging tray that collected photos and text and then sent them somewhere.
/// That screen made sense while the destination was the point of the app. Now the entry is
/// the point, so attaching things is something you do to an entry that already exists, which
/// is where the editor's own controls already do it.
///
/// Entries sits left because that is where a recording lands and where you go right after
/// making one. Settings holds appearance, backup, export, import and the optional
/// integrations.
struct HomeView: View {
    @Environment(AppServices.self) private var services
    @State private var tab: Tab = .record

    /// Set by a finished dump so the entry it created can be opened. Lives here rather than
    /// in either tab, because it is a message from one to the other.
    @State private var openEntry: UUID?
    /// Shown once, on the first launch, and never again unless Settings asks for it.
    @AppStorage(Self.onboardedKey) private var hasOnboarded = false
    @State private var showingOnboarding = false

    static let onboardedKey = "hasSeenOnboarding"

    enum Tab: Hashable { case entries, record, settings }

    var body: some View {
        TabView(selection: $tab) {
            DraftListView(openEntry: $openEntry)
                .tabItem { Label("Entries", systemImage: "square.stack.fill") }
                .tag(Tab.entries)

            NavigationStack {
                RecordView { draftId in
                    // Land the person on what they just made, so the transformation is the
                    // first thing they see rather than something they have to go and find.
                    openEntry = draftId
                    tab = .entries
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) { Wordmark(size: 19) }
                }
            }
            .tabItem { Label("Record", systemImage: "mic.fill") }
            .tag(Tab.record)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .tint(Brand.violet)
        // The bar shrinks to a pill while you are reading and comes back the moment you
        // reach for it. Standing still it is a wide translucent slab parked on top of
        // whatever photo happens to be at the bottom of the list, which reads as a second
        // panel dropped over the app rather than as its navigation.
        //
        // This is the system's own answer to that, not a redrawn tab bar: the floating
        // capsule is iOS 26, and replacing it with a flat fixed bar would cost more than
        // the crowding does.
        .modifier(MinimizingTabBar())
        // Full screen and not dismissible by swipe: it is three sentences and one button,
        // and someone who flicks it away by accident has learned none of them.
        .fullScreenCover(isPresented: $showingOnboarding) {
            OnboardingView {
                hasOnboarded = true
                showingOnboarding = false
                // Lands on Record, which is where the button it was just pressed says to go.
                tab = .record
            }
        }
        .task { if !hasOnboarded { showingOnboarding = true } }
    }
}

/// `tabBarMinimizeBehavior` is iOS 26, and the app still deploys to 17.
private struct MinimizingTabBar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
    }
}
