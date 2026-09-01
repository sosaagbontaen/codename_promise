import CodenamePromiseCore
import SwiftUI

/// Connect a Notion workspace and choose where entries go.
///
/// The two states are deliberately distinct on screen: signing in and picking a database are
/// separate steps, and stopping halfway is a normal place to be rather than a broken one.
/// Nothing here is required — an entry that never syncs is complete (tenet 4), so this screen
/// never nags.
struct NotionSettingsView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    @State private var coordinator: ConnectionCoordinator?
    @State private var authenticator = WebAuthenticator()
    @State private var confirmingDisconnect = false
    @State private var serverURL = ""
    @State private var serverSaved = false
    @AppStorage(Appearance.storageKey) private var appearance: Appearance = .dark
    @State private var showingExport = false
    @State private var showingFeedback = false

    var body: some View {
        NavigationStack {
            Group {
                if let coordinator {
                    content(coordinator)
                } else {
                    List {
                        serverSection
                        Section {
                            Text("Point this app at a running backend to enable dictation, formatting and Notion. Your entries are saved on this device either way.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        localSections
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingExport) {
                if let store = services.store, let files = services.files {
                    ExportView(store: store, fileStore: files)
                }
            }
            .sheet(isPresented: $showingFeedback) { FeedbackView() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            await services.reminders.refreshAuthorization()
            serverURL = AppServices.backendSettings.overrideValue
                ?? AppServices.backendSettings.bundled ?? ""
            if coordinator == nil, let service = services.connectionService {
                coordinator = ConnectionCoordinator(service: service)
            }
            await coordinator?.refresh()
        }
    }

    @ViewBuilder
    private func content(_ coordinator: ConnectionCoordinator) -> some View {
        List {
            if case .failed(let message) = coordinator.phase {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Brand.failed)
                    Button("Dismiss") { coordinator.dismissError() }
                }
            }

            if coordinator.isUnavailable {
                Section {
                    // The user can't fix this, so don't offer them a button that will fail.
                    Label(
                        "This server doesn't have Notion set up. Nothing to do here yet.",
                        systemImage: "info.circle"
                    )
                    .foregroundStyle(.secondary)
                }
            } else {
                serverSection
                statusSection(coordinator)
                if coordinator.status.connected {
                    databaseSection(coordinator)
                    disconnectSection(coordinator)
                }
            }

            Section {
                Text("Syncing is optional. Entries live on this device whether or not Notion is connected.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            localSections
        }
        .overlay {
            if coordinator.phase == .loading && coordinator.databases.isEmpty {
                ProgressView()
            }
        }
        .confirmationDialog(
            "Disconnect Notion?",
            isPresented: $confirmingDisconnect,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                Task { await coordinator.disconnect() }
            }
        } message: {
            Text("Your entries stay on this device. Nothing is deleted from Notion.")
        }
    }

    /// Export and feedback sit here regardless of whether a backend is configured, because
    /// neither needs one. Getting your journal out must never depend on a server being up
    /// -- that would make the backup fail in exactly the circumstances you need it.
    @ViewBuilder
    private var localSections: some View {
        Section {
            Picker(selection: $appearance) {
                ForEach(Appearance.allCases) { Text($0.label).tag($0) }
            } label: {
                Label("Appearance", systemImage: "circle.lefthalf.filled")
            }
            .pickerStyle(.menu)
        } footer: {
            Text("Dark by default \u{2014} the brand was drawn that way, and most dumping happens at the end of a day.")
        }

        Section {
            Button {
                showingExport = true
            } label: {
                Label("Export your journal", systemImage: "square.and.arrow.up.on.square")
            }
        } footer: {
            Text("Markdown and media, saved wherever you like. Works offline and needs nothing else to read it.")
        }

        Section {
            Button {
                showingFeedback = true
            } label: {
                Label("Send feedback", systemImage: "envelope")
            }
        } footer: {
            Text("Ideas, problems, or just hello. Nothing from your entries is ever attached.")
        }

        Section {
            Toggle(isOn: reminderBinding) {
                Label("Remind me to write", systemImage: "bell")
            }
        } footer: {
            Text(reminderFooter)
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

    private var reminderFooter: String {
        switch services.reminders.authorization {
        case .denied:
            "Notifications are off for this app in iOS Settings."
        default:
            "One quiet nudge after a few days without an entry, at the hour you usually write. It is scheduled on this device \u{2014} nothing about your habits leaves the phone."
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
    private var serverSection: some View {
        Section {
            TextField("http://192.168.1.20:8077", text: $serverURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .onSubmit(saveServerURL)

            Button("Save server address", action: saveServerURL)
                .disabled(!serverURL.isEmpty && !BackendSettings.isValid(serverURL))

            if serverSaved {
                Label("Saved — reopen the app to apply.", systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(Brand.reached)
            }
        } header: {
            Text("Server")
        } footer: {
            if let bundled = AppServices.backendSettings.bundled,
               AppServices.backendSettings.isUsingOverride {
                Text("Overriding the built-in address (\(bundled)). Leave blank to go back to it. On a physical device use your Mac's IP on the local network, not localhost.")
            } else {
                Text("On a physical device use your Mac's IP on the local network — localhost points at the phone itself. Leave blank to use the built-in address.")
            }
        }
    }

    @ViewBuilder
    private func statusSection(_ coordinator: ConnectionCoordinator) -> some View {
        Section("Workspace") {
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

                Text("Opens Notion so you can sign in and choose what to share. Your password and access token never reach this app.")
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

    private func saveServerURL() {
        AppServices.backendSettings.setOverride(serverURL)
        serverSaved = true
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
