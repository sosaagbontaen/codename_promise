import Foundation
import SwiftData
import Testing
@testable import CodenamePromiseCore

/// Which photo represents a day.
///
/// `orderedMedia.first` is what the entry list and the collage show, so the order is not a
/// cosmetic detail: it decides the picture somebody sees when they scroll past a day. It used
/// to be decided by UUID string, because `sortIndex` was never assigned and every item sat
/// at 0 — an order nobody chose and nothing could change.
@Suite("Media order", .serialized)
@MainActor
struct MediaOrderTests {

    private func makeFileStore() throws -> MediaFileStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return MediaFileStore(root: root)
    }

    /// Writes a file and attaches it, returning the item.
    private func attach(
        _ name: String, to draft: EntryDraft, store: DraftStore, files: MediaFileStore
    ) throws -> MediaItem {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).jpg")
        try Data(name.utf8).write(to: source)
        return try store.attachMedia(from: source, kind: .photo, to: draft, fileStore: files)
    }

    @Test("photos keep the order they were added in")
    func attachOrderIsKept() throws {
        let store = DraftStore(container: try ModelContainerFactory.makeInMemoryContainer())
        let files = try makeFileStore()
        let draft = try store.createDraft()

        var added: [UUID] = []
        for name in ["one", "two", "three", "four"] {
            added.append(try attach(name, to: draft, store: store, files: files).id)
        }
        #expect(draft.orderedMedia.map(\.id) == added)
    }

    @Test("reordering decides which photo is the cover")
    func reorderingSetsTheCover() throws {
        let store = DraftStore(container: try ModelContainerFactory.makeInMemoryContainer())
        let files = try makeFileStore()
        let draft = try store.createDraft()

        var ids: [UUID] = []
        for name in ["one", "two", "three"] {
            ids.append(try attach(name, to: draft, store: store, files: files).id)
        }

        try store.reorderMedia([ids[2], ids[0], ids[1]], in: draft)
        #expect(draft.orderedMedia.map(\.id) == [ids[2], ids[0], ids[1]])
        #expect(draft.orderedMedia.first?.id == ids[2], "the cover is the first one")
    }

    /// A caller passing a stale list must not silently lose somebody's photograph.
    @Test("a photo left out of the order is kept, not dropped")
    func omittedPhotosSurvive() throws {
        let store = DraftStore(container: try ModelContainerFactory.makeInMemoryContainer())
        let files = try makeFileStore()
        let draft = try store.createDraft()

        var ids: [UUID] = []
        for name in ["one", "two", "three"] {
            ids.append(try attach(name, to: draft, store: store, files: files).id)
        }

        // Only two of the three named.
        try store.reorderMedia([ids[2], ids[0]], in: draft)
        #expect(draft.orderedMedia.count == 3)
        #expect(draft.orderedMedia.map(\.id).prefix(2).elementsEqual([ids[2], ids[0]]))
        #expect(draft.orderedMedia.contains { $0.id == ids[1] })
    }

    @Test("ids that are not on the draft are ignored")
    func strangersAreIgnored() throws {
        let store = DraftStore(container: try ModelContainerFactory.makeInMemoryContainer())
        let files = try makeFileStore()
        let draft = try store.createDraft()
        let only = try attach("one", to: draft, store: store, files: files).id

        try store.reorderMedia([UUID(), only, UUID()], in: draft)
        #expect(draft.orderedMedia.map(\.id) == [only])
    }

    @Test("a new photo lands at the end rather than jumping the queue")
    func newPhotosAppend() throws {
        let store = DraftStore(container: try ModelContainerFactory.makeInMemoryContainer())
        let files = try makeFileStore()
        let draft = try store.createDraft()

        var ids: [UUID] = []
        for name in ["one", "two"] {
            ids.append(try attach(name, to: draft, store: store, files: files).id)
        }
        try store.reorderMedia([ids[1], ids[0]], in: draft)

        let late = try attach("three", to: draft, store: store, files: files).id
        #expect(draft.orderedMedia.map(\.id) == [ids[1], ids[0], late])
    }

    /// The order has to be committed, not merely held in memory: the entry list reads it
    /// from a fresh context on the next launch.
    @Test("the chosen order survives a relaunch")
    func orderIsCommitted() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let files = try makeFileStore()
        let draftId: UUID
        var expected: [UUID] = []

        do {
            let store = DraftStore(container: container)
            let draft = try store.createDraft()
            draftId = draft.id
            var ids: [UUID] = []
            for name in ["one", "two", "three"] {
                ids.append(try attach(name, to: draft, store: store, files: files).id)
            }
            expected = [ids[1], ids[2], ids[0]]
            try store.reorderMedia(expected, in: draft)
        }

        let reopened = DraftStore(container: container)
        let recovered = try #require(try reopened.draft(id: draftId))
        #expect(recovered.orderedMedia.map(\.id) == expected)
    }
}
