import Foundation
import SwiftData
import Testing
@testable import CodenamePromiseCore

/// Moving attachments between entries.
///
/// The workflow this exists for: a week of photos gets imported by capture date, a few land
/// on the wrong day, and fixing it by hand meant deleting each one and re-picking it from the
/// library. `removeMedia` deletes the bytes (ADR-018a), so that repair is a data-loss window
/// the user has to walk through — exactly the shape of thing this project refuses to ship.
@Suite("Moving media between entries")
@MainActor
struct MoveMediaTests {

    private func makeStore() throws -> (DraftStore, MediaFileStore, URL) {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (DraftStore(container: container), MediaFileStore(root: root), root)
    }

    /// Writes a file with recognisable bytes so we can prove the *same* bytes moved.
    private func makeSource(_ marker: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("incoming-\(UUID().uuidString).jpg")
        try Data(marker.utf8).write(to: url)
        return url
    }

    @Test("photos move to the other entry")
    func movesToDestination() throws {
        let (store, files, _) = try makeStore()
        let monday = try store.createDraft()
        let tuesday = try store.createDraft()

        let a = try store.attachMedia(from: try makeSource("a"), kind: .photo, to: monday, fileStore: files)
        let b = try store.attachMedia(from: try makeSource("b"), kind: .photo, to: monday, fileStore: files)
        let c = try store.attachMedia(from: try makeSource("c"), kind: .photo, to: monday, fileStore: files)

        let moved = try store.moveMedia(ids: [a.id, c.id], from: monday, to: tuesday)

        #expect(moved == 2)
        #expect(monday.orderedMedia.map(\.id) == [b.id])
        #expect(Set(tuesday.orderedMedia.map(\.id)) == [a.id, c.id])
    }

    /// The whole point of moving rather than re-attaching: no copy, no delete, no window in
    /// which the photo exists nowhere.
    @Test("the bytes are never touched")
    func bytesAreUntouched() throws {
        let (store, files, root) = try makeStore()
        let from = try store.createDraft()
        let to = try store.createDraft()

        let item = try store.attachMedia(from: try makeSource("original bytes"), kind: .photo, to: from, fileStore: files)
        let path = item.relativePath
        let before = try Data(contentsOf: root.appendingPathComponent(path))

        try store.moveMedia(ids: [item.id], from: from, to: to)

        let after = try #require(to.orderedMedia.first)
        #expect(after.relativePath == path, "a move must not re-file the bytes")
        #expect(try Data(contentsOf: root.appendingPathComponent(path)) == before)
        #expect(String(data: before, encoding: .utf8) == "original bytes")
    }

    /// The bug that made this feature necessary to get right: media was not part of the sync
    /// fingerprint, so moving photos changed nothing either destination would ever hear about.
    @Test("both entries are left needing a sync")
    func bothEntriesBecomeDirty() throws {
        let (store, files, _) = try makeStore()
        let from = try store.createDraft()
        let to = try store.createDraft()
        try store.updateRawText("monday", for: from)
        try store.updateRawText("tuesday", for: to)

        let item = try store.attachMedia(from: try makeSource("x"), kind: .photo, to: from, fileStore: files)

        // Pretend both were synced exactly as they stand.
        from.syncState(for: .notion).markSynced(externalId: "page-from", contentHash: from.contentHash)
        to.syncState(for: .notion).markSynced(externalId: "page-to", contentHash: to.contentHash)
        try store.flush()
        #expect(!from.needsSync(to: .notion))
        #expect(!to.needsSync(to: .notion))

        try store.moveMedia(ids: [item.id], from: from, to: to)

        #expect(from.needsSync(to: .notion), "the page it left still shows the photo")
        #expect(to.needsSync(to: .notion), "the page it arrived at has never seen it")
    }

    @Test("moving everything leaves the source empty rather than broken")
    func movingAllIsFine() throws {
        let (store, files, _) = try makeStore()
        let from = try store.createDraft()
        let to = try store.createDraft()

        let a = try store.attachMedia(from: try makeSource("a"), kind: .photo, to: from, fileStore: files)
        let b = try store.attachMedia(from: try makeSource("b"), kind: .photo, to: from, fileStore: files)

        try store.moveMedia(ids: [a.id, b.id], from: from, to: to)

        #expect(from.orderedMedia.isEmpty)
        #expect(to.orderedMedia.count == 2)
    }

    @Test("arriving photos are appended after what is already there, in order")
    func arrivalOrderIsStable() throws {
        let (store, files, _) = try makeStore()
        let from = try store.createDraft()
        let to = try store.createDraft()

        let existing = try store.attachMedia(from: try makeSource("existing"), kind: .photo, to: to, fileStore: files)
        let first = try store.attachMedia(from: try makeSource("1"), kind: .photo, to: from, fileStore: files)
        let second = try store.attachMedia(from: try makeSource("2"), kind: .photo, to: from, fileStore: files)

        try store.moveMedia(ids: [first.id, second.id], from: from, to: to)

        #expect(to.orderedMedia.map(\.id) == [existing.id, first.id, second.id])
    }

    @Test("moving an entry's photos onto itself does nothing")
    func selfMoveIsANoOp() throws {
        let (store, files, _) = try makeStore()
        let draft = try store.createDraft()
        let item = try store.attachMedia(from: try makeSource("a"), kind: .photo, to: draft, fileStore: files)

        #expect(try store.moveMedia(ids: [item.id], from: draft, to: draft) == 0)
        #expect(draft.orderedMedia.count == 1)
    }

    @Test("an id that isn't on the source entry is ignored, not fatal")
    func unknownIdsAreIgnored() throws {
        let (store, files, _) = try makeStore()
        let from = try store.createDraft()
        let to = try store.createDraft()
        let item = try store.attachMedia(from: try makeSource("a"), kind: .photo, to: from, fileStore: files)

        let moved = try store.moveMedia(ids: [item.id, UUID()], from: from, to: to)

        #expect(moved == 1)
        #expect(to.orderedMedia.count == 1)
    }

    /// A move is a mutation, so it obeys ADR-001 like every other one.
    @Test("the move is committed before it returns")
    func moveIsDurable() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = MediaFileStore(root: root)

        let toId: UUID
        let itemId: UUID
        do {
            let store = DraftStore(container: container)
            let from = try store.createDraft()
            let to = try store.createDraft()
            toId = to.id
            let item = try store.attachMedia(from: try makeSource("a"), kind: .photo, to: from, fileStore: files)
            itemId = item.id
            try store.moveMedia(ids: [item.id], from: from, to: to)
        }

        // A second store with its own context sees only what was actually committed.
        let reopened = DraftStore(container: container)
        let destination = try #require(try reopened.draft(id: toId))
        #expect(destination.orderedMedia.map(\.id) == [itemId])
    }
}
