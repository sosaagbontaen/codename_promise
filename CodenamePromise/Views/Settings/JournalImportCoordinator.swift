import CodenamePromiseCore
import Foundation
import Observation

/// Runs a journal import for as long as it takes, independently of the screen showing it.
///
/// A year of a migrated journal is thousands of photos, minutes of copying. Tied to its sheet,
/// closing the sheet or leaving the app ended it. Here it carries on: the sheet is a view onto
/// it, and `BackgroundWork` keeps it going after the app is left, with its progress on the
/// Lock Screen. If iOS stops it anyway, importing the same folder again finishes the entry it
/// was on and skips everything already in.
@MainActor
@Observable
final class JournalImportCoordinator {
    enum Phase: Equatable {
        case idle
        case working(JournalImportProgress)
        case done(DraftStore.ImportReport)
        case failed(String)
    }

    private(set) var phase = Phase.idle

    private let store: DraftStore
    private let fileStore: MediaFileStore

    init(store: DraftStore, fileStore: MediaFileStore) {
        self.store = store
        self.fileStore = fileStore
    }

    var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    func start(_ folder: URL) {
        guard !isWorking else { return }
        phase = .working(JournalImportProgress())
        Task { await run(folder) }
    }

    /// Back to the start, once a finished or failed import has been seen.
    func reset() {
        if !isWorking { phase = .idle }
    }

    private func run(_ folder: URL) async {
        // A folder from the document picker lives outside the sandbox and has to be opened
        // explicitly, and closed even when the import throws.
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        await BackgroundWork.run(title: "Importing \(folder.lastPathComponent)") { report in
            do {
                let result = try await store.importJournal(from: folder, fileStore: fileStore) { progress in
                    phase = .working(progress)
                    // In thousandths, so the Live Activity's bar matches the one on screen.
                    report(
                        Int(progress.fraction * 1000), 1000,
                        progress.isReading
                            ? "Getting entries: \(progress.readDone) of \(progress.readTotal)"
                            : "\(progress.entriesDone) of \(progress.entriesTotal) entries, \(progress.filesDone) of \(progress.filesTotal) photos"
                    )
                }
                Haptics.picked()
                phase = .done(result)
            } catch {
                Haptics.failed()
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
