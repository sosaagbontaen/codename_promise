import CodenamePromiseCore
import SwiftUI

/// Settings, as a home screen of topics rather than one long page.
///
/// It used to be every control the app has in one scrolling list, footnotes and all, which
/// read like a spec rather than a place you'd want to be. Now each topic is a tile that says
/// how it's set at a glance, and opens a short page with just its own controls.
///
/// Nothing here is required. An entry that never syncs is complete (tenet 4), so the screen
/// never nags.
struct SettingsView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    /// False when this is a tab rather than a sheet: a tab has nothing to dismiss.
    var showsDone = true

    @State private var coordinator: ConnectionCoordinator?
    @State private var authenticator = WebAuthenticator()
    @State private var confirmingDisconnect = false
    @State private var serverURL = ""
    @State private var serverSaved = false
    /// Never pre-filled from the Keychain: reading a stored secret back into a field just
    /// to show it is a way to leak it over somebody's shoulder. Blank means "unchanged".
    @State private var apiKey = ""
    @State private var apiKeySaved = false
    @State private var revealingAPIKey = false
    @State private var checking = false
    @State private var checkResult: BackendCheck?
    @AppStorage(Appearance.storageKey) private var appearance: Appearance = .dark
    @AppStorage(JournalFont.storageKey) private var journalFont: JournalFont = .sans
    // Stored as its raw string rather than as the enum. @AppStorage does support a
    // RawRepresentable, so this is a preference for the unambiguous form rather than a
    // workaround: what lands in UserDefaults is exactly what BackupMode(rawValue:) reads
    // back, on both sides of the app/Core boundary.
    @AppStorage(AppServices.backupModeKey) private var backupModeRaw = BackupMode.thisPhoneOnly.rawValue
    @State private var showingExport = false
    @State private var showingImport = false
    @State private var showingFeedback = false
    @State private var showingServer = false
    @State private var corrections = NameCorrectionStore().load().corrections
    @State private var trashCount = 0

    /// One page per setting.
    enum Page: Hashable {
        case look, backup, mac, names, sync, reminders, export, help, trash, photos
    }

    var body: some View {
        NavigationStack {
            List {
                Section("App") {
                    row(.look, "Appearance", "circle.lefthalf.filled", Brand.violet,
                        "\(appearance.label) mode \u{00B7} \(journalFont.label)")
                }
                Section("Data") {
                    row(.backup, "Backup", services.isBackedUp ? "On, to iCloud" : "This iPhone only") {
                        SettingsIcon.iCloud
                    }
                    row(.export, "Import and export", "arrow.up.arrow.down", Brand.Mode.extra, nil)
                    row(.photos, "Fill in from Photos", "photo.on.rectangle.angled", Brand.Mode.photo, nil)
                    row(.trash, "Recently Deleted", "trash.fill", Color(uiColor: .systemGray), trashStatus)
                }
                Section("Connections") {
                    row(.mac, "Your Mac", "laptopcomputer", Brand.violet,
                        CaptureInbox.isMacFolderConnected ? "Connected" : "Not connected")
                    row(.sync, "Notion", syncStatus.text, alert: syncStatus.alert) {
                        SettingsIcon.notion
                    }
                }
                Section("Personalization") {
                    row(.names, "Dictionary", "character.book.closed.fill", Brand.Mode.photo, dictionaryStatus)
                    row(.reminders, "Reminders", "bell.fill", Brand.waiting,
                        reminderStatus)
                }
                Section {
                    row(.help, "Help and feedback", "questionmark.circle.fill", Brand.violet, nil)
                } header: {
                    Text("Support")
                } footer: {
                    Text(versionLine)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.ground)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Page.self) { page in
                pageView(page)
            }
            .toolbar {
                if showsDone {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .sheet(isPresented: $showingExport) {
                if let store = services.store, let files = services.files {
                    ExportView(store: store, fileStore: files)
                }
            }
            .sheet(isPresented: $showingImport) {
                if let importer = services.journalImport {
                    ImportView(importer: importer)
                }
            }
            .sheet(isPresented: $showingFeedback) { FeedbackView() }
        }
        .task {
            await services.reminders.refreshAuthorization()
            trashCount = (try? services.store?.trashedCount()) ?? 0
            serverURL = AppServices.backendSettings.overrideValue
                ?? AppServices.backendSettings.bundled ?? ""
            if coordinator == nil, let service = services.connectionService {
                coordinator = ConnectionCoordinator(service: service)
            }
            await coordinator?.refresh()
        }
    }

    // MARK: - Home

    private var trashStatus: String? {
        trashCount == 0 ? nil : "\(trashCount) \(trashCount == 1 ? "entry" : "entries"), kept for 30 days"
    }

    /// "Daily at 8:00 PM", "Sundays at 9:00 AM", or "Off".
    private var reminderStatus: String {
        let reminders = services.reminders
        guard reminders.isEnabled else { return "Off" }
        let time = (Calendar.current.date(
            bySettingHour: reminders.minuteOfDay / 60, minute: reminders.minuteOfDay % 60, second: 0, of: Date()
        ) ?? Date()).formatted(date: .omitted, time: .shortened)
        switch reminders.frequency {
        case .whenAway: return "When you\u{2019}ve been away"
        case .daily: return "Daily at \(time)"
        case .weekly: return "\(Calendar.current.weekdaySymbols[reminders.weekday - 1])s at \(time)"
        }
    }

    /// "3 words: Lizzy, Aidan, …", so the row says what's in it.
    private var dictionaryStatus: String {
        guard !corrections.isEmpty else { return "Words to always spell your way" }
        let shown = corrections.prefix(3).map(\.meant).joined(separator: ", ")
        let more = corrections.count > 3 ? ", \u{2026}" : ""
        return "\(corrections.count) \(corrections.count == 1 ? "word" : "words"): \(shown)\(more)"
    }

    /// One setting: a small coloured icon, its name, and how it's set.
    private func row(
        _ page: Page, _ title: String, _ symbol: String, _ tint: Color, _ status: String?,
        alert: Bool = false
    ) -> some View {
        row(page, title, status, alert: alert) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// The same row with an icon of its own, for services with a recognisable mark.
    private func row<Icon: View>(
        _ page: Page, _ title: String, _ status: String?, alert: Bool = false,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        NavigationLink(value: page) {
            HStack(spacing: 12) {
                icon()
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .foregroundStyle(Brand.ink)
                    if let status {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(alert ? Brand.failed : Brand.muted)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var syncStatus: (text: String, alert: Bool) {
        guard let coordinator else { return ("Not set up", false) }
        if case .failed = coordinator.phase { return ("Can\u{2019}t reach it", true) }
        if coordinator.isUnavailable { return ("Not available", false) }
        if coordinator.status.ready { return (coordinator.status.workspaceName ?? "Connected", false) }
        if coordinator.status.connected { return ("Pick a database", true) }
        return ("Not connected", false)
    }

    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return "DumpNotes \(version) (\(build))"
    }

    // MARK: - Pages

    @ViewBuilder
    private func pageView(_ page: Page) -> some View {
        switch page {
        case .trash:
            if let store = services.store, let files = services.files {
                RecentlyDeletedView(store: store, fileStore: files)
                    .onDisappear { trashCount = (try? store.trashedCount()) ?? 0 }
            }
        case .photos:
            if let filler = services.photoBackfill {
                FillFromPhotosView(filler: filler)
                    .scrollContentBackground(.hidden)
                    .background(Brand.ground)
            }
        case .names:
            if let store = services.store {
                NameCorrectionsView(store: store)
                    .onDisappear { corrections = NameCorrectionStore().load().corrections }
            }
        default:
            List {
                pageContent(page)
            }
            .scrollContentBackground(.hidden)
            .background(Brand.ground)
            .navigationTitle(title(of: page))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func title(of page: Page) -> String {
        switch page {
        case .look: "Appearance"
        case .backup: "Backup"
        case .mac: "Your Mac"
        case .names: "Dictionary"
        case .sync: "Notion"
        case .reminders: "Reminders"
        case .export: "Import and export"
        case .help: "Help and feedback"
        case .trash: "Recently Deleted"
        case .photos: "Fill in from Photos"
        }
    }

    @ViewBuilder
    private func pageContent(_ page: Page) -> some View {
        switch page {
        case .look:
        Section {
            Picker(selection: $appearance) {
                ForEach(Appearance.allCases) { Text($0.label).tag($0) }
            } label: {
                Label("Appearance", systemImage: "circle.lefthalf.filled")
            }
            .pickerStyle(.menu)
        } footer: {
            Text("Dark by default. Most journaling happens at the end of a day.")
        }

            AppIconPicker()
        // Set in the face itself, because nobody can pick a reading font from its name.
        Section {
            ForEach(JournalFont.allCases) { choice in
                Button {
                    journalFont = choice
                    Haptics.picked()
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Text(choice.label)
                                    .font(Type.label(15, .semibold))
                                    .foregroundStyle(Brand.ink)
                                Text(choice.note)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            // The sample sits under the name and at reading size, because the
                            // point of showing it is the thing a name cannot tell you.
                            Text("The evening was warmer than we expected.")
                                .font(choice.font(size: 16, weight: 400))
                                .foregroundStyle(Brand.muted)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: journalFont == choice
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(journalFont == choice ? Brand.violet : Brand.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.row)
            }
        } header: {
            // Names the control, not the reason for it. "Your writing" was the scope rule
            // wearing a section header: accurate about what the setting touches and silent
            // about what it does, so it read as a heading for settings *about* entries.
            Text("Journal font")
        } footer: {
            Text("The type your entries are written and shown in.")
        }


        case .backup:
            backupSection

        case .mac:
            MacInboxSection()

        case .names, .trash, .photos:
            EmptyView()

        case .sync:
            syncContent

        case .reminders:
            Section {
                Toggle(isOn: reminderBinding) {
                    Label("Remind me to write", systemImage: "bell")
                }
            } footer: {
                if !services.reminders.isEnabled { Text(reminderFooter) }
            }

            if services.reminders.isEnabled {
                Section {
                    Picker("How often", selection: reminderSetting(\.frequency)) {
                        ForEach(ReminderScheduler.Frequency.allCases) { Text($0.label).tag($0) }
                    }
                    if services.reminders.frequency == .weekly {
                        Picker("Day", selection: reminderSetting(\.weekday)) {
                            ForEach(1...7, id: \.self) { day in
                                Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                            }
                        }
                    }
                    if services.reminders.frequency != .whenAway {
                        DatePicker("Time", selection: reminderTime, displayedComponents: .hourAndMinute)
                    }
                } footer: {
                    Text(services.reminders.frequency == .whenAway
                         ? "One nudge after \(ReminderScheduler.idleDays) days without an entry, at the hour you usually write."
                         : "Scheduled on this iPhone. Nothing about your habits leaves it.")
                }
            }

        case .export:
            Section {
                Button {
                    showingExport = true
                } label: {
                    Label("Export your journal", systemImage: "square.and.arrow.up.on.square")
                }
                Button {
                    showingImport = true
                } label: {
                    Label("Import a journal", systemImage: "square.and.arrow.down.on.square")
                }
            } footer: {
                Text("Markdown and media, readable without this app. Importing only ever adds, so doing it twice is safe.")
            }

        case .help:
            Section {
                Button {
                    showingFeedback = true
                } label: {
                    Label("Send feedback", systemImage: "envelope")
                }
                Button {
                    UserDefaults.standard.set(false, forKey: HomeView.onboardedKey)
                    Haptics.picked()
                } label: {
                    Label("Show the welcome again", systemImage: "sparkles.rectangle.stack")
                }
            } footer: {
                Text("Feedback never includes your entries. The welcome comes back next time you open the app.")
            }
        }
    }

    /// Notion first, the server behind it folded away. The address and key are what make
    /// everything else work, so they're always reachable, including when the connection is
    /// broken, but they're plumbing, not what anyone comes here to see.
    @ViewBuilder
    private var syncContent: some View {
        if let coordinator {
            if case .failed(let message) = coordinator.phase {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Brand.failed)
                    Button("Dismiss") { coordinator.dismissError() }
                }
            }
            if coordinator.isUnavailable {
                Section {
                    Label("This server doesn\u{2019}t have Notion set up.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            } else {
                statusSection(coordinator)
                if coordinator.status.connected {
                    databaseSection(coordinator)
                    disconnectSection(coordinator)
                }
            }
        } else {
            Section {
                Text("Connect a server to send entries to Notion and to turn recordings into text. Your entries are saved on this iPhone either way.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        Section {
            DisclosureGroup("Server", isExpanded: Binding(
                get: { showingServer || coordinator == nil },
                set: { showingServer = $0 }
            )) {
                serverRows
            }
        } footer: {
            Text("Syncing is optional. Entries live on this iPhone whether or not Notion is connected.")
        }
    }

    /// Backup, said in terms of where the journal is rather than which technology moves it.
    ///
    /// Two things here are deliberate. The switch reports what actually happened rather than
    /// what was asked for, because a control reading iCloud while nothing syncs is worse than
    /// no control at all. And the footer says the switch takes effect next launch instead of
    /// quietly doing nothing until then: the store and the media root are both chosen when
    /// they are opened.
    @ViewBuilder
    private var backupSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { backupModeRaw == BackupMode.iCloud.rawValue },
                set: { backupModeRaw = ($0 ? BackupMode.iCloud : .thisPhoneOnly).rawValue }
            )) {
                Label("Back up to iCloud", systemImage: "icloud")
            }

            if let why = services.backupUnavailable {
                Label(why, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(Brand.waiting)
            } else if backupModeRaw == BackupMode.iCloud.rawValue, !services.isBackedUp {
                Label(
                    "Restart the app to start backing up.",
                    systemImage: "arrow.clockwise"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        } footer: {
            // Says whose iCloud, because "backed up" in a journalling app raises exactly the
            // question this sentence answers.
            Text("Your own iCloud, not our servers. Photos added before you turn this on stay in your iPhone backup.")
        }
    }

    /// A toggle rather than a request on launch: a journaling app that demands notification
    /// access before you have written anything is asking for a favour it has not earned.
    private var reminderBinding: Binding<Bool> {
        Binding(
            get: { services.reminders.isEnabled },
            set: { wanted in
                guard let store = services.store else { return }
                if wanted {
                    Task { await services.reminders.enable(using: store) }
                } else {
                    services.reminders.disable()
                }
            }
        )
    }

    /// A reminder preference that reschedules as soon as it changes.
    private func reminderSetting<Value>(_ keyPath: ReferenceWritableKeyPath<ReminderScheduler, Value>) -> Binding<Value> {
        Binding(
            get: { services.reminders[keyPath: keyPath] },
            set: { value in
                services.reminders[keyPath: keyPath] = value
                if let store = services.store { services.reminders.reschedule(using: store) }
            }
        )
    }

    private var reminderTime: Binding<Date> {
        Binding(
            get: {
                let minutes = services.reminders.minuteOfDay
                return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                services.reminders.minuteOfDay = (parts.hour ?? 20) * 60 + (parts.minute ?? 0)
                if let store = services.store { services.reminders.reschedule(using: store) }
            }
        )
    }

    private var reminderFooter: String {
        switch services.reminders.authorization {
        case .denied:
            "Notifications are off for this app in iOS Settings."
        default:
            "One quiet nudge after a few days without an entry, at the hour you usually write. It is scheduled on this device, so nothing about your habits leaves the phone."
        }
    }

    // MARK: - Sections

    /// Where the backend lives, editable on the device.
    ///
    /// One build cannot serve both targets: `localhost` is correct in the simulator, which
    /// shares the Mac's network stack, and meaningless on a phone where `localhost` is the
    /// phone. Without this field, running on a real device just says "no backend configured"
    /// with nothing the user can do about it.
    @ViewBuilder
    private var serverRows: some View {
            TextField("http://192.168.1.20:8077", text: $serverURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .onSubmit(saveServerURL)

            Button("Save server address", action: saveServerURL)
                .disabled(!serverURL.isEmpty && !BackendSettings.isValid(serverURL))

            if serverSaved {
                Label("Saved. In use from the next request.", systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(Brand.reached)
            }

            // Nothing wrote to the Keychain before this existed. APIKeyStore().read() was
            // consulted on every request and always came back nil, so a backend that
            // required a key could only ever answer 401 — and the only way to run one was
            // to leave it open, which on a public URL is somebody else's free inference.
            HStack(spacing: 8) {
                // Swapped rather than overlaid, because SecureField cannot be asked to stop
                // being secure. The cost is that focus is lost on the toggle, which is worth
                // it: typing forty characters of key blind and finding out it was wrong only
                // when every request returns 401 is worse.
                Group {
                    if revealingAPIKey {
                        TextField("API key, if your server needs one", text: $apiKey)
                    } else {
                        SecureField("API key, if your server needs one", text: $apiKey)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(saveAPIKey)

                Button {
                    revealingAPIKey.toggle()
                } label: {
                    Image(systemName: revealingAPIKey ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(revealingAPIKey ? "Hide the API key" : "Show the API key")
            }

            Button("Save API key", action: saveAPIKey)

            if apiKeySaved {
                Label("Saved to the Keychain.", systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(Brand.reached)
            }

            // "Saved" only ever meant "written down", which is not the question anybody is
            // asking. This answers the actual one, and distinguishes a wrong address from a
            // wrong key — the two failures that used to look identical.
            Button {
                Task { await runCheck() }
            } label: {
                HStack(spacing: 8) {
                    Label("Check connection", systemImage: "antenna.radiowaves.left.and.right")
                    if checking { ProgressView().controlSize(.small) }
                }
            }
            .disabled(checking)

            if let checkResult {
                Label(checkResult.message, systemImage: Self.symbol(for: checkResult))
                    .font(.footnote)
                    .foregroundStyle(Self.tint(for: checkResult))
            }
            Text("A hosted address, or your Mac\u{2019}s IP on the local network. Leave blank for the built-in one.")
                .font(.footnote)
                .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func statusSection(_ coordinator: ConnectionCoordinator) -> some View {
        Section {
            if coordinator.status.connected {
                HStack {
                    Label(
                        coordinator.status.workspaceName ?? "Connected",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(Brand.reached)
                    Spacer()
                }
            } else {
                Button {
                    Task { await connect(coordinator) }
                } label: {
                    if coordinator.phase == .authorizing {
                        HStack { ProgressView().controlSize(.small); Text("Signing in…") }
                    } else {
                        Label("Connect Notion", systemImage: "link")
                    }
                }
                .disabled(coordinator.phase == .authorizing || coordinator.authorizationURL == nil)

                Text("You sign in on Notion\u{2019}s own page. Your password never reaches this app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func databaseSection(_ coordinator: ConnectionCoordinator) -> some View {
        Section {
            if coordinator.databases.isEmpty {
                Text("No databases shared yet. Reconnect and pick some pages to share.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(coordinator.databases) { database in
                    Button {
                        Task { await coordinator.selectDatabase(database) }
                    } label: {
                        HStack {
                            Text(database.title)
                                .foregroundStyle(.primary)
                            Spacer()
                            if coordinator.selectingDatabaseId == database.id {
                                ProgressView().controlSize(.small)
                            } else if coordinator.status.databaseId == database.id {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Database")
        } footer: {
            if coordinator.status.ready {
                Text("Entries are filed by the day they're about, one page per day.")
            } else {
                Text("Pick where entries should go. It needs a date column.")
            }
        }
    }

    @ViewBuilder
    private func disconnectSection(_ coordinator: ConnectionCoordinator) -> some View {
        Section {
            Button("Disconnect", role: .destructive) { confirmingDisconnect = true }
        }
    }

    // MARK: - Actions

    /// Asks the server two questions rather than one, because the answers fail differently.
    private func runCheck() async {
        checking = true
        checkResult = nil
        defer { checking = false }

        guard let client = services.apiClient else {
            checkResult = .noAddress
            return
        }
        checkResult = await BackendChecker(
            client: client, hasStoredKey: { APIKeyStore().read() != nil }
        ).check()

        if checkResult?.isWorking == true { Haptics.landed() } else { Haptics.failed() }
    }

    /// Green only when it genuinely works. A stub server answers everything happily and
    /// transcribes nothing, so it gets the warning colour rather than the reassuring one.
    private static func tint(for result: BackendCheck) -> Color {
        if result.hasRealProviders { return Brand.reached }
        if case .noAddress = result { return .secondary }
        return result.isWorking ? Brand.waiting : Brand.failed
    }

    private static func symbol(for result: BackendCheck) -> String {
        if result.hasRealProviders { return "checkmark.circle.fill" }
        if case .noAddress = result { return "info.circle" }
        return result.isWorking ? "exclamationmark.circle.fill" : "xmark.circle.fill"
    }

    private func saveAPIKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            APIKeyStore().delete()
        } else {
            try? APIKeyStore().write(trimmed)
        }
        apiKey = ""
        revealingAPIKey = false
        apiKeySaved = true
        checkResult = nil
        Haptics.picked()
    }

    private func saveServerURL() {
        AppServices.backendSettings.setOverride(serverURL)
        serverSaved = true
        checkResult = nil
    }

    private func connect(_ coordinator: ConnectionCoordinator) async {
        guard let url = coordinator.authorizationURL else { return }
        coordinator.beginAuthorizing()

        switch await authenticator.authenticate(url: url, callbackScheme: "codenamepromise") {
        case .completed:
            await coordinator.finishAuthorizing(cancelled: false)
        case .cancelled:
            await coordinator.finishAuthorizing(cancelled: true)
        case .failed(let message):
            coordinator.authorizationFailed(message)
        }
    }
}

/// Icons for the services people already know by their marks.
enum SettingsIcon {
    /// iCloud as iOS Settings draws it: Apple's cloud, white, on a blue gradient.
    static var iCloud: some View {
        Image(systemName: "icloud.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.36, green: 0.73, blue: 1.0), Color(red: 0.0, green: 0.48, blue: 1.0)],
                    startPoint: .top, endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: 8)
            )
    }

    /// Notion's mark: a black N on a white tile with a heavy black outline. Drawn rather than
    /// bundled; swap in the official asset if one is added to the catalogue as "NotionLogo".
    @ViewBuilder
    static var notion: some View {
        if UIImage(named: "NotionLogo") != nil {
            Image("NotionLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.white)
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.black, lineWidth: 2)
                    .padding(4)
                Text("N")
                    .font(.system(size: 15, weight: .black, design: .serif))
                    .foregroundStyle(.black)
            }
            .frame(width: 30, height: 30)
        }
    }
}
