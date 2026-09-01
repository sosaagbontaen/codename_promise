import CodenamePromiseCore
import SwiftUI

/// Three places, with Dump in the middle.
///
/// Centre because it is the thumb's home and the thing you open the app to do — the concept's
/// real contribution is that capture is not a mode you enter from a list. Entries sits left
/// because that is where a dump lands, and you go there right after making one.
///
/// Everything underneath is unchanged. Entries is the same day-grouped list with open-days,
/// import-by-date, multi-select and move; Settings is the same screen with export, feedback
/// and reminders.
struct HomeView: View {
    @Environment(AppServices.self) private var services
    @State private var tab: Tab = .dump

    /// Set by a finished dump so the entry it created can be opened. Lives here rather than
    /// in either tab, because it is a message from one to the other.
    @State private var openEntry: UUID?
    /// How many things are staged on the Dump tab, so the tray can react to them.
    @State private var staged = 0
    /// Owned here so the blast reaches the tab bar too, not just the screen that caused it.
    @State private var impact = DumpImpact()

    enum Tab: Hashable { case entries, dump, settings }

    var body: some View {
        TabView(selection: $tab) {
            DraftListView(openEntry: $openEntry)
                .tabItem { Label("Entries", systemImage: "square.stack.fill") }
                .tag(Tab.entries)

            NavigationStack {
                DumpView(stagedCount: $staged, impact: impact) { draftId in
                    // Land the person on what they just made, unsynced and editable, rather
                    // than on an empty box that gives no sign anything happened.
                    openEntry = draftId
                    tab = .entries
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) { Wordmark(size: 19) }
                }
            }
            .tabItem {
                // A tab icon that never changes is furniture. This one fills the moment
                // there is something waiting to be dumped.
                Label { Text("Dump") } icon: { TrayBadge(count: staged) }
            }
            .tag(Tab.dump)

            NotionSettingsView()
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
        .dumpImpact(impact)
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
