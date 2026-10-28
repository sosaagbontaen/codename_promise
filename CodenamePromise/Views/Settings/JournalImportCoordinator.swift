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
        // An import iOS closed the app in the middle of. It finishes by itself rather than
        // waiting to be noticed: running it again is safe (it skips what's in and completes
        // the entry it was on). A moment's wait so the app is on screen, which the Live
        // Activity needs.
        if let folder = Self.interruptedFolder() {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.start(folder)
            }
        }
    }

    /// The folder of an import that never finished, kept as a bookmark because access to a
    /// folder picked in Files doesn't otherwise survive the app closing.
    private static let inProgressKey = "journalImport.inProgressFolder"

    private static func interruptedFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: inProgressKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else {
            UserDefaults.standard.removeObject(forKey: inProgressKey)
            return nil
        }
        return url
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
        if let bookmark = try? folder.bookmarkData() {
            UserDefaults.standard.set(bookmark, forKey: Self.inProgressKey)
        }
        // Cleared however it ends, finished or failed; only being closed mid-way leaves it.
        defer { UserDefaults.standard.removeObject(forKey: Self.inProgressKey) }

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
