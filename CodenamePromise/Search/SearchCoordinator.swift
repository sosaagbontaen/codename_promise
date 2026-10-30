import CodenamePromiseCore
import Foundation
import Observation
import SwiftData

/// Keeps the search index in step with the journal.
///
/// Entries are quick: their words are reindexed whenever the journal has changed since last
/// time. Photos are slow, a fraction of a second each, so they're read in the background,
/// newest first, a few dozen at a time, and each batch is saved as it goes. Stopping partway
/// loses nothing: the next pass skips every photo already read.
@MainActor
@Observable
final class SearchCoordinator {
    let index: SearchIndex
    private let store: DraftStore
    private let fileStore: MediaFileStore

    /// Photos read so far out of all of them, while a pass is running.
    private(set) var photosRead = 0
    private(set) var photosTotal = 0
    private(set) var readingPhotos = false

    private var indexedRevision: Int?
    private var entryPass: Task<Void, Never>?
    private var photoPass: Task<Void, Never>?
    /// Raised when the journal changes during a photo pass, so photos just added are read
    /// next instead of after the thousands already queued.
    private let journalChanged = Flag()

    init(index: SearchIndex, store: DraftStore, fileStore: MediaFileStore) {
        self.index = index
        self.store = store
        self.fileStore = fileStore
    }

    /// Brings the index up to date. Cheap when nothing has changed; safe to call often.
    func refresh() {
        let changes = indexedRevision.map { store.changes(since: $0) }
        if let changes, changes.isEmpty {
            readPhotos()
            return
        }
        indexedRevision = store.revision

        let container = store.context.container
        let index = index
        let only: Set<UUID>? = changes.flatMap { $0.structural ? nil : $0.draftIds }
        let previous = entryPass
        entryPass = Task.detached(priority: .utility) {
            await previous?.value
            await Self.indexEntries(container: container, index: index, only: only)
        }
        journalChanged.raise()
        readPhotos()
    }

    /// Writes each entry's words to the index; with `only`, just those entries.
    nonisolated private static func indexEntries(container: ModelContainer, index: SearchIndex, only: Set<UUID>?) async {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<EntryDraft>()
        if let only {
            let ids = Array(only)
            descriptor.predicate = #Predicate { ids.contains($0.id) }
        }
        guard let drafts = try? context.fetch(descriptor) else { return }
        var rows: [(id: UUID, day: String, title: String, body: String)] = []
        var gone: [UUID] = []
        for draft in drafts {
            if draft.isTrashed { gone.append(draft.id); continue }
            let words = RichDocument.words(ofMarkdown: draft.content.rawText)
            let title = draft.content.title.flatMap { $0.isEmpty ? nil : $0 } ?? ""
            rows.append((draft.id, draft.entryDateKey, title, words))
        }
        if only == nil {
            // A full pass also clears out entries deleted for good.
            let present = Set(drafts.map(\.id))
            gone += await index.indexedEntryIds().subtracting(present)
        } else {
            // Asked about but no longer there at all.
            gone += only!.subtracting(drafts.map(\.id))
        }
        await index.removeEntries(gone)
        for start in stride(from: 0, to: rows.count, by: 500) {
            await index.indexEntries(Array(rows[start..<min(start + 500, rows.count)]))
        }
    }

    /// True while "Finish now" is running the rest as one job.
    private(set) var finishing = false

    /// Reads every photo and video not read yet. One pass at a time.
    private func readPhotos() {
        guard photoPass == nil else { return }
        photoPass = startPass(width: 3, priority: .utility)
    }

    private func startPass(width: Int, priority: TaskPriority) -> Task<Void, Never> {
        readingPhotos = true
        let container = store.context.container
        let index = index
        let fileStore = fileStore
        let changed = journalChanged
        _ = changed.take()
        return Task.detached(priority: priority) { [weak self] in
            await Self.readPhotos(container: container, index: index, fileStore: fileStore,
                                  changed: changed, width: width) { read, total in
                self?.photosRead = read
                self?.photosTotal = total
            }
            await MainActor.run {
                self?.readingPhotos = false
                self?.photoPass = nil
            }
        }
    }

    /// Reads everything left as one job: more photos at once, at full priority, the screen
    /// kept on, and its progress on the Lock Screen so it carries on when the app is left.
    func finishNow() async {
        guard !finishing else { return }
        finishing = true
        defer { finishing = false }
        // The everyday pass makes way rather than running beside it.
        photoPass?.cancel()
        await photoPass?.value
        await BackgroundWork.run(title: "Reading photos for search") { report in
            let pass = startPass(width: 4, priority: .userInitiated)
            photoPass = pass
            let watcher = Task { @MainActor in
                while !Task.isCancelled {
                    report(photosRead, max(photosTotal, 1),
                           "\(photosRead.formatted()) of \(photosTotal.formatted()) photos read")
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            await pass.value
            watcher.cancel()
        }
    }

    nonisolated private static func readPhotos(
        container: ModelContainer,
        index: SearchIndex,
        fileStore: MediaFileStore,
        changed: Flag,
        width: Int,
        progress: @escaping @MainActor (Int, Int) -> Void
    ) async {
        planning: while !Task.isCancelled {
            let context = ModelContext(container)
            guard let items = try? context.fetch(FetchDescriptor<MediaItem>()) else { return }
            struct Pending: Sendable { let id: UUID; let draftId: UUID; let day: String; let url: URL; let isVideo: Bool }
            let all: [Pending] = items.compactMap { item in
                guard let draft = item.draft else { return nil }
                return Pending(id: item.id, draftId: draft.id, day: draft.entryDateKey,
                               url: fileStore.url(for: item.relativePath), isVideo: item.kind == .video)
            }

            // Photos removed for good are forgotten, and photos moved to another entry since
            // they were read are refiled, without reading them again.
            let placements = await index.mediaPlacements()
            let present = Set(all.map(\.id))
            await index.removeMedia(placements.keys.filter { !present.contains($0) })
            let moves = all.compactMap { item -> (id: UUID, draftId: UUID, day: String)? in
                guard let placed = placements[item.id], placed.draftId != item.draftId || placed.day != item.day else { return nil }
                return (item.id, item.draftId, item.day)
            }
            if !moves.isEmpty { await index.placeMedia(moves) }

            let read = await index.readMediaIds()
            // Newest days first: what's most likely to be searched for.
            let waiting = all.filter { !read.contains($0.id) }.sorted { $0.day > $1.day }
            var done = all.count - waiting.count
            await progress(done, all.count)

            var batch: [SearchIndex.MediaReading] = []
            var stalledInARow = 0
            // A photo that times out gets one more go at the end: the first after launch can
            // run out of time while Vision loads its models.
            var queue = waiting[...]
            var retried = Set<UUID>()
            var replan = false
            // Several photos at once: Vision spends much of each one waiting on the Neural
            // Engine, so a few in flight keep it busy.
            await withTaskGroup(of: (Pending, PhotoReader.Outcome).self) { group in
                var inFlight = 0
                func launch() {
                    while inFlight < width, let item = queue.popFirst() {
                        inFlight += 1
                        group.addTask { (item, await PhotoReader.read(item.url, isVideo: item.isVideo)) }
                    }
                }
                launch()
                while let (item, outcome) = await group.next() {
                    inFlight -= 1
                    if Task.isCancelled { group.cancelAll(); return }
                    switch outcome {
                    case .read(let reading):
                        stalledInARow = 0
                        batch.append(.init(id: item.id, draftId: item.draftId, day: item.day,
                                           words: reading.words, labels: reading.labels, complete: reading.complete))
                        done += 1
                    case .unreadable:
                        // Not downloaded from iCloud yet, most likely. Not recorded, so the
                        // next pass tries it again.
                        done += 1
                    case .timedOut:
                        stalledInARow += 1
                        if retried.insert(item.id).inserted { queue.append(item) } else { done += 1 }
                    }
                    // Vision stalling on photo after photo is Vision, not the photos: stop and
                    // try again next launch rather than spend the battery waiting on it.
                    if stalledInARow >= 3 + width { group.cancelAll(); return }
                    if batch.count >= 24 {
                        await index.indexMedia(batch)
                        batch.removeAll()
                        await progress(done, all.count)
                    }
                    if changed.take() {
                        // Something was added or moved: plan again, so it's read next.
                        replan = true
                        group.cancelAll()
                        return
                    }
                    launch()
                }
            }
            if replan {
                await index.indexMedia(batch)
                continue planning
            }
            await index.indexMedia(batch)
            await progress(done, all.count)
            break
        }
    }
}

/// A thread-safe yes/no, raised on the main actor and taken by the background pass.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func raise() {
        lock.withLock { raised = true }
    }

    /// Whether it was raised, lowering it.
    func take() -> Bool {
        lock.withLock {
            defer { raised = false }
            return raised
        }
    }
}
