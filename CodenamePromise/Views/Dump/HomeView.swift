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

    enum Tab: Hashable { case entries, dump, settings }

    var body: some View {
        TabView(selection: $tab) {
            DraftListView(openEntry: $openEntry)
                .tabItem { Label("Entries", systemImage: "square.stack.fill") }
                .tag(Tab.entries)

            NavigationStack {
                DumpView { draftId in
                    // Land the person on what they just made, unsynced and editable, rather
                    // than on an empty box that gives no sign anything happened.
                    openEntry = draftId
                    tab = .entries
                }
                .navigationTitle(Bundle.main.appDisplayName)
                .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("Dump", systemImage: "tray.and.arrow.down.fill") }
            .tag(Tab.dump)

            NotionSettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .tint(Brand.violet)
    }
}
