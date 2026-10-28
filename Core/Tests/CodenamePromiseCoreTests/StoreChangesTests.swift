import Foundation
import Testing

@testable import CodenamePromiseCore

/// The journal list updates from these instead of re-reading every entry, so they must never
/// miss a change: a missed one is a list that quietly shows old words.
@Suite("Store changes")
@MainActor
struct StoreChangesTests {
    let store: DraftStore
    init() throws { store = DraftStore(container: try ModelContainerFactory.makeInMemoryContainer()) }

    @Test func nothingSavedMeansNothingChanged() throws {
        _ = try store.createDraft()
        let start = store.revision
        try store.flush()
        #expect(store.changes(since: start).isEmpty)
    }

    @Test func aNewEntryIsNamed() throws {
        let start = store.revision
        let a = try store.createDraft()
        #expect(store.changes(since: start).draftIds.contains(a.id))
    }

    @Test func aPhotoRemovedNamesItsEntry() throws {
        let a = try store.createDraft()
        let photo = MediaItem(kind: .photo, relativePath: "Media/x.jpg", originalSizeBytes: 1)
        a.media.append(photo)
        try store.flush()
        let start = store.revision
        a.media.removeAll()
        store.context.delete(photo)
        try store.flush()
        #expect(store.changes(since: start).draftIds.contains(a.id))
    }

    @Test func aDeletedEntryIsStructural() throws {
        let a = try store.createDraft()
        let start = store.revision
        store.context.delete(a)
        try store.flush()
        #expect(store.changes(since: start).structural)
    }

    @Test func editsNameTheEntry() throws {
        let a = try store.createDraft(), b = try store.createDraft()
        let start = store.revision
        try store.updateRawText("hello", for: a)
        let changes = store.changes(since: start)
        #expect(changes.draftIds == [a.id])
        #expect(!changes.structural)
        _ = b
    }

    @Test func aPhotoAddedNamesItsEntry() throws {
        let a = try store.createDraft()
        let start = store.revision
        a.media.append(MediaItem(kind: .photo, relativePath: "Media/x.jpg", originalSizeBytes: 1))
        try store.flush()
        #expect(store.changes(since: start).draftIds.contains(a.id))
    }

    @Test func autosavedChangesAreSeenToo() throws {
        let a = try store.createDraft()
        let start = store.revision
        // A mutation that skips the store's methods, saved by the context directly the way
        // autosave would.
        a.updateTitle("Changed elsewhere")
        try store.context.save()
        #expect(store.changes(since: start).draftIds == [a.id])
    }

    @Test func trashingAndRestoringAreSeen() throws {
        let a = try store.createDraft()
        var since = store.revision
        try store.moveToTrash(a)
        #expect(store.changes(since: since).draftIds.contains(a.id))
        since = store.revision
        try store.restore(a)
        #expect(store.changes(since: since).draftIds.contains(a.id))
    }
}
