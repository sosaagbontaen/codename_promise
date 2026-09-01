import SwiftUI

/// Three places, which is the concept's real contribution: capture is not a mode you enter
/// from a list, it is where the app opens.
///
/// Everything underneath is unchanged — Journal is the same day-grouped list with open-days,
/// import-by-date, multi-select and move; Settings is the same screen with export and
/// feedback. The tab bar reframes them rather than replacing them.
struct HomeView: View {
    @Environment(AppServices.self) private var services
    @State private var tab: Tab = .dump

    enum Tab: Hashable { case dump, journal, settings }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                DumpView()
                    .navigationTitle(Bundle.main.appDisplayName)
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("Dump", systemImage: "tray.and.arrow.down.fill") }
            .tag(Tab.dump)

            DraftListView()
                .tabItem { Label("Journal", systemImage: "book.closed.fill") }
                .tag(Tab.journal)

            NotionSettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .tint(Brand.violet)
    }
}
