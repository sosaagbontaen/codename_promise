import CodenamePromiseCore
import Foundation
import Observation

/// Runs a journal import for as long as it takes, independently of the screen showing it.
///
/// A year of a migrated journal is thousands of photos, minutes of copying. Tied to its sheet,
/// closing the sheet or leaving the app ended it. Here it carries on: the sheet is a view onto
/// it, and `BackgroundWork` keeps it going after the app is left, with its progress on the
/// Lock Screen. If iOS stops it anyway, importing the same folders again finishes the entry it
/// was on and skips everything already in.
///
/// Takes several folders at once, or one folder holding several (a year per folder, the way
/// an export is laid out), so a whole journal is one import rather than one per year.
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
    /// The folder being imported now, and where it falls in the run ("2019", 3 of 9).
    private(set) var folder: (name: String, number: Int, of: Int)?

    private let store: DraftStore
    private let fileStore: MediaFileStore

    init(store: DraftStore, fileStore: MediaFileStore) {
        self.store = store
        self.fileStore = fileStore
        // An import iOS closed the app in the middle of. It finishes by itself rather than
        // waiting to be noticed: running it again is safe (it skips what's in and completes
        // the entry it was on). A moment's wait so the app is on screen, which the Live
        // Activity needs.
        let interrupted = Self.interruptedFolders()
        if !interrupted.isEmpty {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.start(interrupted)
            }
        }
    }

    /// The folders of an import that never finished, kept as bookmarks because access to a
    /// folder picked in Files doesn't otherwise survive the app closing.
    private static let inProgressKey = "journalImport.inProgressFolders"

    private static func interruptedFolders() -> [URL] {
        guard let saved = UserDefaults.standard.array(forKey: inProgressKey) as? [Data] else { return [] }
        let urls = saved.compactMap { data -> URL? in
            var stale = false
            return try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
        }
        if urls.isEmpty { UserDefaults.standard.removeObject(forKey: inProgressKey) }
        return urls
    }

    var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    func start(_ picked: [URL]) {
        guard !isWorking, !picked.isEmpty else { return }
        phase = .working(JournalImportProgress())
        Task { await run(picked) }
    }

    /// Back to the start, once a finished or failed import has been seen.
    func reset() {
        if !isWorking { phase = .idle }
    }

    private func run(_ picked: [URL]) async {
        // Folders from the document picker live outside the sandbox and have to be opened
        // explicitly, and closed even when the import throws. Opening a parent opens the
        // year folders inside it too.
        let scoped = picked.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        UserDefaults.standard.set(picked.compactMap { try? $0.bookmarkData() }, forKey: Self.inProgressKey)
        // Cleared however it ends, finished or failed; only being closed mid-way leaves it.
        defer { UserDefaults.standard.removeObject(forKey: Self.inProgressKey) }

        let folders = Self.journalFolders(in: picked)
        guard !folders.isEmpty else {
            phase = .failed("No journal entries in that folder. Pick a folder an export produced, or the folder that holds them.")
            return
        }

        let title = folders.count == 1 ? "Importing \(folders[0].lastPathComponent)" : "Importing \(folders.count) folders"
        await BackgroundWork.run(title: title) { report in
            var total = DraftStore.ImportReport()
            do {
                for (number, folder) in folders.enumerated() {
                    self.folder = (folder.lastPathComponent, number + 1, folders.count)
                    let result = try await store.importJournal(from: folder, fileStore: fileStore) { progress in
                        phase = .working(progress)
                        // The whole run as one bar: each folder its share, in thousandths so
                        // the Live Activity's bar matches the one on screen.
                        let overall = (Double(number) + progress.fraction) / Double(folders.count)
                        let place = folders.count == 1 ? "" : "\(folder.lastPathComponent) (\(number + 1) of \(folders.count)): "
                        report(
                            Int(overall * 1000), 1000,
                            place + (progress.isReading
                                ? "getting entries, \(progress.readDone) of \(progress.readTotal)"
                                : "\(progress.entriesDone) of \(progress.entriesTotal) entries, \(progress.filesDone) of \(progress.filesTotal) photos")
                        )
                    }
                    total.absorb(result)
                }
                Haptics.picked()
                phase = .done(total)
            } catch {
                Haptics.failed()
                phase = .failed(error.localizedDescription)
            }
            self.folder = nil
        }
    }

    /// The folders that hold entries: each picked folder that has them itself, and for one
    /// that doesn't, the folders inside it that do. In name order, so years run oldest first,
    /// with "Brought back" last: its photos are for entries the years bring in.
    static func journalFolders(in picked: [URL]) -> [URL] {
        let manager = FileManager.default
        func holdsEntries(_ url: URL) -> Bool {
            ((try? manager.contentsOfDirectory(atPath: url.path)) ?? []).contains {
                let name = $0.lowercased()
                return (name.hasSuffix(".md") || name.hasSuffix(".md.icloud")) && name != "readme.md"
            }
        }
        var folders: [URL] = []
        for url in picked {
            if holdsEntries(url) {
                folders.append(url)
                continue
            }
            let inside = ((try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .filter(holdsEntries)
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            folders += inside
        }
        let additions = folders.filter { $0.lastPathComponent == "Brought back" }
        return folders.filter { $0.lastPathComponent != "Brought back" } + additions
    }
}

extension DraftStore.ImportReport {
    /// Adds another folder's results to these.
    mutating func absorb(_ other: DraftStore.ImportReport) {
        added += other.added
        alreadyPresent += other.alreadyPresent
        attachments += other.attachments
        updated += other.updated
        additionsWaiting += other.additionsWaiting
        importedIds += other.importedIds
        missingAttachments += other.missingAttachments
        unreadable += other.unreadable
    }
}
