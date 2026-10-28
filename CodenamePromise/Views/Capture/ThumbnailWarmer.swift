import CodenamePromiseCore
import Foundation
import SwiftData

/// Makes the journal's thumbnails ahead of time, in the background, so scrolling draws from
/// disk instead of decoding photos.
///
/// Runs after an import or a fill from Photos, and once at launch to catch up. Covers the
/// photos the journal shows: the first four of each entry at grid size, and the first at
/// list size. Reads with its own context off the main actor, so the journal stays responsive
/// while it works, and skips anything already made, so a second run is quick.
enum ThumbnailWarmer {
    @MainActor private static var running: Task<Void, Never>?

    @MainActor
    static func warm(container: ModelContainer, files: MediaFileStore) {
        running?.cancel()
        running = Task.detached(priority: .background) {
            let context = ModelContext(container)
            guard let drafts = try? context.fetch(FetchDescriptor<EntryDraft>(
                predicate: #Predicate { $0.deletedAt == nil },
                sortBy: [SortDescriptor(\.entryDateKey, order: .reverse)]
            )) else { return }
            // Newest first: the part of the journal most likely to be looked at next.
            var grid: [(id: UUID, url: URL, isVideo: Bool)] = []
            var list: [(id: UUID, url: URL, isVideo: Bool)] = []
            for draft in drafts {
                let media = draft.orderedMedia
                let covers = draft.covers
                let shown = covers.isEmpty ? Array(media.prefix(4)) : Array(covers.prefix(4))
                for item in shown {
                    grid.append((item.id, files.url(for: item.relativePath), item.kind == .video))
                }
                if let first = shown.first {
                    list.append((first.id, files.url(for: first.relativePath), first.kind == .video))
                }
            }
            await ThumbnailCache.prepare(list, maxPixel: 162)
            await ThumbnailCache.prepare(grid, maxPixel: 420)
        }
    }
}
