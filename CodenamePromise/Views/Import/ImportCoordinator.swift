import CodenamePromiseCore
import Observation
import OSLog
import PhotosUI
import SwiftUI
import UIKit

private let log = Logger(subsystem: "com.codenamepromise.journal", category: "import")

/// Owns a bulk import for as long as it takes, independently of the screen showing it.
///
/// The import used to live inside its sheet. Anything that dismissed the sheet ended the
/// import, and anything that ended the process lost it — which, for five hundred photos,
/// was not an edge case but the expected outcome: the phone auto-locks long before that many
/// are read, and a locked phone is a backgrounded app iOS is free to reclaim.
///
/// So the work lives here, for the life of the app, and every step of it is written to an
/// `ImportSession` on disk as it happens. The sheet is only a view onto it. Close the sheet
/// and the import carries on; lose the process and the next launch brings it back.
@MainActor
@Observable
final class ImportCoordinator {
    private(set) var session: ImportSession?
    /// Reading photos out of the picker.
    private(set) var staging: (done: Int, total: Int)?
    /// Attaching confirmed photos to entries.
    private(set) var applying: (done: Int, total: Int)?
    /// What happened last time, when it is worth saying.
    private(set) var notice: String?
    private(set) var lastOutcome: ImportApplier.Outcome?

    /// Whether the import screen should be up. True from the first pick until the import is
    /// finished or discarded — including after a relaunch, which is the point.
    var isPresented: Bool {
        get { presented }
        set {
            presented = newValue
            // Swiping the sheet away is not cancelling. The photos stay staged and the
            // import is waiting where it was left, on the next visit.
        }
    }
    private var presented = false

    private let store: DraftStore
    private let fileStore: MediaFileStore
    private let sessions: ImportSessionStore

    /// Photos in flight at once. Reading from the picker is mostly waiting — on iCloud
    /// downloads, on the file system — so a few at a time is several times faster than one,
    /// and more than a few just competes for the same disk and network.
    private static let concurrency = 4

    init(store: DraftStore, fileStore: MediaFileStore, sessions: ImportSessionStore) {
        self.store = store
        self.fileStore = fileStore
        self.sessions = sessions
    }

    // MARK: - Coming back

    /// Picks up whatever import was in progress when the app last stopped.
    ///
    /// Called once at launch. An import that was being read comes back as a review of what
    /// was read — the picker's handles do not survive the process, so the rest cannot be
    /// fetched again, and the notice says how many. One that was being applied carries on
    /// applying, which is safe because applying is idempotent.
    func restore() {
        guard var restored = sessions.current() else { return }
        switch restored.phase {
        case .staging:
            restored.phase = .reviewing
            if restored.unread > 0 {
                let unread = restored.unread
                notice = "The app closed before it finished. \(restored.items.count) photos were read; add the other \(unread) with Add more photos."
            }
            persist(restored)
            presented = !restored.items.isEmpty
            if restored.items.isEmpty { discard() }
        case .reviewing:
            session = restored
            presented = true
        case .applying:
            session = restored
            presented = true
            notice = "Picking up where the import left off."
            Task { await runApply() }
        }
    }

    // MARK: - Reading photos in

    /// Starts an import from the first trip to the picker.
    func begin(with items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        // A fresh import replaces any old one that was abandoned rather than finished.
        sessions.discardAll()
        let fresh = ImportSession(requested: items.count)
        do {
            try sessions.prepare(fresh)
        } catch {
            notice = "Couldn\u{2019}t make room for the import: \(error.localizedDescription)"
            return
        }
        session = fresh
        notice = nil
        presented = true
        Task { await stage(items) }
    }

    /// Adds a second batch to the import already under review.
    func add(_ items: [PhotosPickerItem]) {
        guard var current = session, !items.isEmpty else { return }
        current.requested += items.count
        persist(current)
        Task { await stage(items) }
    }

    private func stage(_ items: [PhotosPickerItem]) async {
        guard let started = session else { return }
        let sessions = self.sessions
        let snapshot = started
        let total = items.count
        var done = 0
        staging = (0, total)

        await keepingAwake {
            await withTaskGroup(of: ImportSession.Item?.self) { group in
                var iterator = items.makeIterator()

                // Keep `concurrency` reads in flight, topping up as each finishes.
                func next() -> Bool {
                    guard let item = iterator.next() else { return false }
                    group.addTask { await Self.read(item, into: snapshot, sessions: sessions) }
                    return true
                }
                for _ in 0..<Self.concurrency { guard next() else { break } }

                while let result = await group.next() {
                    done += 1
                    staging = (done, total)
                    if let result, var current = session {
                        current.items.append(result)
                        session = current
                        // Written down the moment it is safe on disk, so leaving now loses
                        // nothing already read.
                        persist(current)
                    }
                    _ = next()
                }
            }
        }

        staging = nil
        if var current = session, current.phase == .staging {
            current.phase = .reviewing
            persist(current)
        }
        if let current = session, current.items.isEmpty {
            notice = "Nothing could be read from those items."
        }
    }

    /// One photo out of the picker and into the import's own directory.
    ///
    /// Runs off the main actor. Nothing here decodes an image: the capture date comes from
    /// the file's metadata and the thumbnail is made later, on demand, at the size shown.
    private nonisolated static func read(
        _ item: PhotosPickerItem,
        into session: ImportSession,
        sessions: ImportSessionStore
    ) async -> ImportSession.Item? {
        let id = UUID()
        let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        do {
            if isVideo {
                guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                    return nil
                }
                let date = await CaptureDateReader.captureDate(ofVideoAt: movie.url)
                let name = try sessions.adopt(fileAt: movie.url, id: id, into: session)
                return ImportSession.Item(id: id, filename: name, kind: .video, capturedAt: date)
            }
            guard let image = try await item.loadTransferable(type: PickedImageFile.self) else {
                return nil
            }
            let date = CaptureDateReader.captureDate(ofImageAt: image.url)
            let name = try sessions.adopt(fileAt: image.url, id: id, into: session)
            return ImportSession.Item(id: id, filename: name, kind: .photo, capturedAt: date)
        } catch {
            log.error("could not read a picked item: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Review

    /// Where a staged photo is, for drawing its thumbnail.
    func url(for item: ImportSession.Item) -> URL? {
        session.map { sessions.url(for: item, in: $0) }
    }

    func setDestination(_ destination: ImportDestination, forGroup id: String) {
        mutate { $0.groupDestinations[id] = destination }
    }

    func setDestination(_ destination: ImportDestination?, forItem id: UUID) {
        mutate { $0.itemDestinations[id] = destination }
    }

    func setTitle(_ title: String, forGroup id: String) {
        mutate { $0.newEntryTitles[id] = title }
    }

    func setNote(_ note: String, forGroup id: String) {
        mutate { $0.groupNotes = ($0.groupNotes ?? [:]).merging([id: note]) { $1 } }
    }

    // MARK: - Applying

    /// Fixes the plan and starts attaching.
    func confirm() {
        guard var current = session, current.phase == .reviewing else { return }
        current.freezePlan { [store] day in
            guard let day, let drafts = try? store.drafts(on: day) else { return [] }
            return drafts.map(\.id)
        }
        persist(current)
        Task { await runApply() }
    }

    private func runApply() async {
        guard var current = session, current.phase == .applying else { return }
        let applier = ImportApplier(store: store, fileStore: fileStore, sessions: sessions)
        applying = (0, current.remaining.count)

        await keepingAwake {
            do {
                let outcome = try await applier.apply(&current) { done, total in
                    self.applying = (done, total)
                }
                lastOutcome = outcome
                session = current
                finish()
            } catch {
                // Stopped partway. Everything done so far is recorded, and applying again
                // carries on from there rather than starting over.
                session = current
                persist(current)
                notice = "Stopped after an error: \(error.localizedDescription). Everything added so far is kept, and Import picks up from there."
            }
        }
        applying = nil
    }

    private func finish() {
        if let session { sessions.discard(session.id) }
        session = nil
        notice = nil
        presented = false
    }

    /// Cancels the import and deletes the staged photos. Nothing already attached is touched.
    func discard() {
        sessions.discardAll()
        session = nil
        staging = nil
        notice = nil
        presented = false
    }

    // MARK: - Plumbing

    private func mutate(_ change: (inout ImportSession) -> Void) {
        guard var current = session else { return }
        change(&current)
        persist(current)
    }

    private func persist(_ updated: ImportSession) {
        session = updated
        do {
            try sessions.save(updated)
        } catch {
            log.error("could not save the import: \(error.localizedDescription)")
        }
    }

    /// Keeps the screen on while a long import runs, and asks for time to finish cleanly if
    /// the person leaves anyway.
    ///
    /// The screen matters most. Auto-lock fires after thirty seconds to five minutes of no
    /// touches, and five hundred photos takes longer than that — so without this, the lock
    /// screen was what ended nearly every large import. Holding it open while there is real
    /// work in flight, and only then, is what video export and file transfer apps do.
    ///
    /// The background task is the second line: if the app is left mid-import it buys the
    /// half-minute iOS allows, which is enough to finish what is in flight and write it down.
    private func keepingAwake(_ work: () async -> Void) async {
        UIApplication.shared.isIdleTimerDisabled = true
        let task = UIApplication.shared.beginBackgroundTask(withName: "photo-import") {
            log.info("background time ran out mid-import; progress is saved")
        }
        await work()
        UIApplication.shared.endBackgroundTask(task)
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
