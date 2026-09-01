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
        let formatting: FormattingCoordinator
        let sync: SyncCoordinator
        let connection: any NotionConnectionService
    }

    enum State {
        case ready(Ready)
        case failed(String)
    }

    private(set) var state: State

    /// Surfaced once at launch if operations were recovered, so an interruption is visible
    /// rather than silent. See ADR-004 / ADR-019a.
    private(set) var recoveryNotice: String?

    init() {
        do {
            let container = try ModelContainerFactory.makeAppContainer()
            let store = DraftStore(container: container)
            let files = try MediaFileStore.makeDefault()

            // Before any UI reads state: demote operations abandoned by a dead process, so
            // nothing is stuck claiming to be in flight. See ADR-004.
            let report = try store.reconcileAbandonedOperations()
            if !report.isEmpty {
                recoveryNotice = Self.describe(report)
            }

            // An absent base URL is not an error: the app then behaves exactly as it does
            // offline — capture works, everything else queues visibly. See ADR-019a.
            let configuration = APIConfiguration(
                baseURL: Self.backendSettings.baseURL,
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
                    formatting: FormattingCoordinator(
                        store: store,
                        service: HTTPFormattingService(client: client)
                    ),
                    sync: SyncCoordinator(
                        store: store,
                        fileStore: files,
                        notion: NotionHTTPClient(client: client),
                        connection: HTTPNotionConnectionService(client: client)
                    ),
                    connection: HTTPNotionConnectionService(client: client)
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
    var formatting: FormattingCoordinator? { ready?.formatting }
    var sync: SyncCoordinator? { ready?.sync }

    /// `nil` when there is no backend at all, which the settings screen presents as
    /// "nothing to configure" rather than as an error.
    var connectionService: (any NotionConnectionService)? {
        guard Self.backendSettings.baseURL != nil else { return nil }
        return ready?.connection
    }

    /// Works through recordings waiting to become text. Safe to call repeatedly — the
    /// coordinator ignores overlapping passes.
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
    static var backendSettings: BackendSettings {
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
        return "Picked up where you left off — " + parts.joined(separator: ", ") + ". Nothing was lost."
    }
}
