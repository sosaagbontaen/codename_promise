import Foundation
import SwiftData
import Testing

@testable import CodenamePromiseCore

/// Recently Deleted: a deleted entry waits thirty days, out of sight, and can come back.
@Suite("Recently Deleted")
@MainActor
struct TrashTests {
    private final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_790_000_000) }

    private func makeStore(_ clock: Clock) throws -> (DraftStore, MediaFileStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cp-trash-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (
            DraftStore(container: try ModelContainerFactory.makeInMemoryContainer(), clock: { clock.now }),
            MediaFileStore(root: root)
        )
    }

    @Test func aTrashedEntryLeavesEveryListButCanComeBack() throws {
        let clock = Clock()
        let (store, _) = try makeStore(clock)
        let day = CalendarDay(rawValue: "2026-10-20")!
        let draft = try store.createDraft(entryDate: day)
        try store.updateRawText("kept", for: draft)

        try store.moveToTrash(draft)
        #expect(try store.allDrafts().isEmpty)
        #expect(try store.drafts(on: day).isEmpty)
        #expect(try store.entryDays(from: day, through: day).isEmpty)
        #expect(try store.earliestEntryDay() == nil)
        #expect(try store.trashedDrafts().map(\.id) == [draft.id])

        try store.restore(draft)
        #expect(try store.allDrafts().map(\.id) == [draft.id])
        #expect(try store.draft(id: draft.id)?.content.rawText == "kept")
    }

    @Test func onlyEntriesPastThirtyDaysArePurged() throws {
        let clock = Clock()
        let (store, files) = try makeStore(clock)
        let old = try store.createDraft()
        try store.moveToTrash(old)
        clock.now = clock.now.addingTimeInterval(20 * 86_400)
        let recent = try store.createDraft()
        try store.moveToTrash(recent)

        clock.now = clock.now.addingTimeInterval(11 * 86_400)  // old is 31 days in, recent 11
        #expect(try store.purgeTrash(fileStore: files) == 1)
        #expect(try store.draft(id: old.id) == nil)
        #expect(try store.trashedDrafts().map(\.id) == [recent.id])
    }
}
