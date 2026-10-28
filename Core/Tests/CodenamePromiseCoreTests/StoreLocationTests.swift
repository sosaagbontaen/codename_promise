import Foundation
import SwiftData
import Testing

@testable import CodenamePromiseCore

/// Gaining an App Group moved SwiftData's default store, which made a phone open an empty
/// journal beside its real one. These pin the fix: the store is chosen explicitly, and
/// entries in the old one are brought across rather than stranded.
@Suite("Store location")
@MainActor
struct StoreLocationTests {
    let root: URL
    let location: StoreLocation

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "store-location-\(UUID())")
        try FileManager.default.createDirectory(at: root.appending(path: "app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "group"), withIntermediateDirectories: true)
        location = StoreLocation(
            legacy: root.appending(path: "app/default.store"),
            group: root.appending(path: "group/default.store")
        )
    }

    private func write(_ url: URL, _ build: (DraftStore) throws -> Void) throws {
        let container = try ModelContainerFactory.makeAppContainer(url: url)
        try build(DraftStore(container: container))
    }

    private func drafts(at url: URL) throws -> [EntryDraft] {
        let container = try ModelContainerFactory.makeAppContainer(url: url)
        return try ModelContext(container).fetch(FetchDescriptor<EntryDraft>())
    }

    @Test func freshInstallUsesTheAppContainer() {
        #expect(location.active == location.legacy)
        #expect(location.pendingMerge == nil)
    }

    @Test func existingPhoneKeepsItsStore() throws {
        try write(location.legacy) { _ = try $0.createDraft() }
        #expect(location.active == location.legacy)
        #expect(location.pendingMerge == nil)
    }

    @Test func groupStoreWinsOnceItExists() throws {
        try write(location.group!) { _ = try $0.createDraft() }
        #expect(location.active == location.group)
        #expect(location.pendingMerge == nil)
    }

    @Test func entriesOnlyInTheOldStoreAreCopiedWithEverythingThatHangsOffThem() throws {
        var oldId = UUID()
        var sharedId = UUID()
        try write(location.legacy) { store in
            let draft = try store.createDraft(entryDate: CalendarDay(rawValue: "2025-03-04")!)
            draft.updateRawText("From before the move")
            draft.updateTitle("Old entry")
            draft.media.append(MediaItem(kind: .photo, relativePath: "Media/a.jpg", originalSizeBytes: 10))
            draft.audioCaptures.append(AudioCapture(relativePath: "Audio/a.m4a", durationSeconds: 3, sizeBytes: 9))
            let sync = SyncState(target: .notion)
            sync.externalId = "page-1"
            sync.attemptId = "attempt-1"
            draft.syncStates.append(sync)
            try store.flush()
            oldId = draft.id

            let shared = try store.createDraft()
            shared.updateRawText("old wording")
            try store.flush()
            sharedId = shared.id
        }
        // The same entry, edited since in the new store, plus one only the new store has.
        try write(location.group!) { store in
            let shared = try store.createDraft(id: sharedId)
            shared.updateRawText("new wording")
            _ = try store.createDraft()
            try store.flush()
        }

        let target = try ModelContainerFactory.makeAppContainer(url: location.active)
        let report = try ModelContainerFactory.mergeLegacyStore(at: location.pendingMerge!, into: target)
        #expect(report.copied == 1)
        #expect(report.alreadyPresent == 1)

        let all = try drafts(at: location.group!)
        #expect(all.count == 3)
        let copied = try #require(all.first { $0.id == oldId })
        #expect(copied.content.rawText == "From before the move")
        #expect(copied.content.title == "Old entry")
        #expect(copied.entryDate.rawValue == "2025-03-04")
        #expect(copied.media.map(\.relativePath) == ["Media/a.jpg"])
        #expect(copied.audioCaptures.map(\.relativePath) == ["Audio/a.m4a"])
        #expect(copied.syncStates.first?.externalId == "page-1")
        #expect(copied.syncStates.first?.attemptId == "attempt-1")
        // The edited copy wins; the old wording is not written over it.
        #expect(all.first { $0.id == sharedId }?.content.rawText == "new wording")
    }

    @Test func theOldStoreIsSetAsideNotDeletedAndNotCopiedTwice() throws {
        try write(location.legacy) { _ = try $0.createDraft() }
        try write(location.group!) { _ = try $0.createDraft() }

        let target = try ModelContainerFactory.makeAppContainer(url: location.active)
        let report = try ModelContainerFactory.mergeLegacyStore(at: location.pendingMerge!, into: target)
        let kept = try #require(report.setAsideAt)
        #expect(StoreLocation.exists(kept))
        #expect(!StoreLocation.exists(location.legacy))
        // Next launch: nothing left to merge, so an entry deleted after the merge stays deleted.
        #expect(location.pendingMerge == nil)
        #expect(location.active == location.group)
    }
}
