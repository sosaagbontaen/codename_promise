import CodenamePromiseCore
import Foundation
import Observation
import SwiftData

/// Everything the UI needs, assembled once at launch.
///
/// Note what happens on failure: this does *not* `fatalError`. An app whose entire premise is
/// "never lose work" must not crash-loop on a store it can't open — the user's entries are
/// still on disk, and a crash tells them nothing. Failure becomes a presentable state.
@MainActor
@Observable
final class AppServices {
    /// Scheduled on the device, never from a server. See `ReminderScheduler`.
    let reminders = ReminderScheduler()

    struct Ready {
        let store: DraftStore
        let files: MediaFileStore
        let transcriptions: TranscriptionCoordinator
        let organising: OrganisingCoordinator
        let sync: SyncCoordinator
        let connection: any NotionConnectionService
        /// Kept so Settings can test the connection without rebuilding one.
        let client: APIClient
    }

    enum State {
        case ready(Ready)
        case failed(String)
    }

    private(set) var state: State

    /// Surfaced once at launch if operations were recovered, so an interruption is visible
    /// rather than silent. See ADR-004 / ADR-019a.
    private(set) var recoveryNotice: String?

    /// Where the journal is backed up, as chosen in Settings.
    ///
    /// Read once at launch and not observed afterwards: both the store and the media root
    /// are decided when they are opened, so changing this takes effect on the next launch.
    /// Settings says so rather than pretending the switch is instant.
    static var backupMode: BackupMode {
        get {
            UserDefaults.standard.string(forKey: backupModeKey)
                .flatMap(BackupMode.init(rawValue:)) ?? .thisPhoneOnly
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: backupModeKey) }
    }

    static let backupModeKey = "backupMode"

    /// True only when the store actually opened against iCloud, and the reason when it did
    /// not. Settings reads these rather than the stored preference.
    private(set) var isBackedUp = false
    private(set) var backupUnavailable: String?

    init() {
        do {
            let requested = Self.backupMode
            // Backup may never stop the journal opening: asking for iCloud and not getting
            // it falls back to local and says why. See BackupMode.
            let opening = try ModelContainerFactory.openAppContainer(backup: requested)
            isBackedUp = opening.isBackedUp
            backupUnavailable = opening.unavailable

            let store = DraftStore(container: opening.container)
            // Media follows the store: if iCloud was asked for and refused, media stays
            // local too, rather than splitting the journal across two stories.
            let files = try MediaFileStore.makeDefault(
                backup: opening.isBackedUp ? .iCloud : .thisPhoneOnly
            )

            // Before any UI reads state: demote operations abandoned by a dead process, so
            // nothing is stuck claiming to be in flight. See ADR-004.
            let report = try store.reconcileAbandonedOperations()
            if !report.isEmpty {
                recoveryNotice = Self.describe(report)
            }

            // An absent base URL is not an error: the app then behaves exactly as it does
            // offline — capture works, everything else queues visibly. See ADR-019a.
            let configuration = APIConfiguration(
                // Recomputed per request, so saving a new address in Settings takes
                // effect on the next call rather than the next launch.
                baseURL: { Self.backendSettings.baseURL },
                apiKey: { APIKeyStore().read() }
            )
            let client = APIClient(
                configuration: configuration,
                reachability: PathMonitorReachability()
            )

            state = .ready(
                Ready(
                    store: store,
                    files: files,
                    transcriptions: TranscriptionCoordinator(
                        store: store,
                        fileStore: files,
                        service: HTTPTranscriptionService(client: client)
                    ),
                    organising: OrganisingCoordinator(
                        store: store,
                        service: HTTPOrganisingService(client: client)
                    ),
                    sync: SyncCoordinator(
                        store: store,
                        fileStore: files,
                        notion: NotionHTTPClient(client: client),
                        connection: HTTPNotionConnectionService(client: client)
                    ),
                    connection: HTTPNotionConnectionService(client: client),
                    client: client
                )
            )
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private var ready: Ready? {
        if case .ready(let ready) = state { return ready }
        return nil
    }

    var store: DraftStore? { ready?.store }
    var files: MediaFileStore? { ready?.files }
    var transcriptions: TranscriptionCoordinator? { ready?.transcriptions }
    var organising: OrganisingCoordinator? { ready?.organising }
    var sync: SyncCoordinator? { ready?.sync }
    var apiClient: APIClient? { ready?.client }

    /// `nil` when there is no backend at all, which the settings screen presents as
    /// "nothing to configure" rather than as an error.
    var connectionService: (any NotionConnectionService)? {
        guard Self.backendSettings.baseURL != nil else { return nil }
        return ready?.connection
    }

    /// Works through recordings waiting to become text. Safe to call repeatedly — the
    /// coordinator ignores overlapping passes.
    /// Bumped whenever background work has written to a draft.
    ///
    /// An editor that is already open holds a text buffer rather than binding to the model
    /// (ADR-001), so a transcript arriving behind it is invisible until something says so.
    private(set) var backgroundWrites = 0

    /// Transcribe a finished recording, then arrange it, then say so.
    ///
    /// Lives here rather than in the view that starts it because the view is dismissed
    /// immediately: the entry opens as soon as the audio is durable, and none of this is
    /// worth making somebody watch. On a host that has to wake up first, watching it would
    /// mean a minute of spinner before seeing an entry that was already saved.
    func completeRecording(draftId: UUID) async {
        await drainTranscriptions()
        if organising?.canOrganise(draftId: draftId) == true {
            _ = await organising?.organise(draftId: draftId)
        }
        backgroundWrites += 1
    }

    func drainTranscriptions() async {
        await transcriptions?.drain()
    }

    /// Resolves the backend address: a device-stored override first, then the build setting.
    ///
    /// The override exists because one build cannot serve both targets. `http://localhost:8077`
    /// is right in the simulator, which shares the Mac's network stack, and meaningless on a
    /// physical phone where `localhost` is the phone. Without a runtime override, running on
    /// device just reports "no backend configured".
    ///
    /// The build value comes from `BackendBaseURL` in the Info.plist, which `Config/Info.plist`
    /// populates from `BACKEND_BASE_URL`. Note for anyone tempted to simplify that to
    /// `INFOPLIST_KEY_BackendBaseURL`: that mechanism only recognises Apple's own key names and
    /// silently drops custom ones — no warning, no key, no backend.
    /// `nonisolated` because the client resolves the address per request, from whatever
    /// thread that request is on. Nothing here touches actor state: it reads Info.plist and
    /// UserDefaults, both of which are safe to read concurrently.
    nonisolated static var backendSettings: BackendSettings {
        BackendSettings(
            bundledValue: Bundle.main.object(forInfoDictionaryKey: "BackendBaseURL") as? String
        )
    }

    /// Called on every scene-phase change. This is the flush that autosave cannot be trusted
    /// to perform — see ADR-001.
    func flushOnBackground() {
        store?.flushQuietly()
    }

    func dismissRecoveryNotice() {
        recoveryNotice = nil
    }

    private static func describe(_ report: ReconciliationReport) -> String {
        var parts: [String] = []
        if report.recoveredTranscriptions > 0 {
            parts.append("\(report.recoveredTranscriptions) recording\(report.recoveredTranscriptions == 1 ? "" : "s") still to transcribe")
        }
        if report.recoveredUploads > 0 {
            parts.append("\(report.recoveredUploads) upload\(report.recoveredUploads == 1 ? "" : "s") to retry")
        }
        if report.recoveredSyncStates > 0 {
            parts.append("\(report.recoveredSyncStates) sync\(report.recoveredSyncStates == 1 ? "" : "s") to retry")
        }
        // Deliberately reassuring about the thing that matters: nothing was lost.
        return "Picked up where you left off: " + parts.joined(separator: ", ") + ". Nothing was lost."
    }
}
