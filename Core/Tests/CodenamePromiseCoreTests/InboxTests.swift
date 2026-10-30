import Foundation
import Testing

@testable import CodenamePromiseCore

/// The capture inbox: things dumped in from the share sheet or the Mac, filed when the app
/// next opens.
///
/// The claims under test are the usual ones for this project. Nothing that reaches the inbox
/// is lost, nothing is filed twice however often the drain is interrupted and rerun, and a
/// capture that is still syncing is left alone rather than filed with pieces missing.
@Suite("Capture inbox")
@MainActor
struct InboxTests {

    @MainActor private struct Harness {
        let store: DraftStore
        let files: MediaFileStore
        let inbox: URL
        let scratch: URL
        let ledger: IngestLedger
        var drainer: InboxDrainer {
            InboxDrainer(ingestor: CaptureIngestor(store: store, fileStore: files), ledger: ledger)
        }
    }

    private func makeHarness() throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-inbox-\(UUID().uuidString)", isDirectory: true)
        let media = root.appendingPathComponent("media", isDirectory: true)
        let inbox = root.appendingPathComponent("inbox", isDirectory: true)
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        for dir in [media, inbox, scratch] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let suite = "cp-inbox-tests-\(UUID().uuidString)"
        return Harness(
            store: DraftStore(container: try ModelContainerFactory.makeInMemoryContainer()),
            files: MediaFileStore(root: media),
            inbox: inbox,
            scratch: scratch,
            ledger: IngestLedger(defaults: UserDefaults(suiteName: suite)!)
        )
    }

    private func photo(in dir: URL, named name: String = "IMG.jpg") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("not really a jpeg \(UUID())".utf8).write(to: url)
        return url
    }

    private let day = CalendarDay(rawValue: "2026-03-14")!

    // MARK: - Writing

    @Test func writerPutsTheManifestLastAndCleansUpOnFailure() throws {
        let h = try makeHarness()
        let missing = h.scratch.appendingPathComponent("gone.jpg")
        let writer = CaptureWriter(inbox: h.inbox)

        #expect(throws: (any Error).self) {
            try writer.write(text: "hi", sources: [.init(url: missing, kind: .photo)],
                             destination: .byCaptureDate, source: "mac")
        }
        // No half capture left behind to sit in the inbox forever.
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.inbox.path).isEmpty)
    }

    @Test func writerCopiesWhatItDoesNotOwnAndMovesWhatItDoes() throws {
        let h = try makeHarness()
        let owned = try photo(in: h.scratch, named: "theirs.jpg")
        let temp = try photo(in: h.scratch, named: "temp.jpg")
        try CaptureWriter(inbox: h.inbox).write(
            text: nil,
            sources: [.init(url: owned, kind: .photo), .init(url: temp, kind: .photo, move: true)],
            destination: .byCaptureDate, source: "share"
        )
        #expect(FileManager.default.fileExists(atPath: owned.path))
        #expect(!FileManager.default.fileExists(atPath: temp.path))
    }

    // MARK: - Scanning

    @Test func aCaptureMissingAFileIsLeftUntilItArrives() async throws {
        let h = try makeHarness()
        let source = try photo(in: h.scratch)
        let capture = try CaptureWriter(inbox: h.inbox).write(
            text: "Lunch with Aidan", sources: [.init(url: source, kind: .photo)],
            destination: .init(day: day), source: "mac"
        )
        // Simulate iCloud having synced the manifest but not yet the photo.
        let folder = h.inbox.appendingPathComponent(capture.id.uuidString.lowercased())
        let photoURL = folder.appendingPathComponent(capture.files[0].name)
        let held = h.scratch.appendingPathComponent("held.jpg")
        try FileManager.default.moveItem(at: photoURL, to: held)

        let first = await h.drainer.drain(h.inbox)
        #expect(first.filed.isEmpty)
        #expect(first.waiting == 1, "one capture, however many of its files are missing")
        #expect(try h.store.allDrafts().isEmpty)

        try FileManager.default.moveItem(at: held, to: photoURL)
        let second = await h.drainer.drain(h.inbox)
        #expect(second.filed.photos == 1)
        #expect(second.filed.jots == 1)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func placeholdersAndReservedFilesAreNotCaptures() throws {
        let h = try makeHarness()
        try Data().write(to: h.inbox.appendingPathComponent(".IMG_1.jpg.icloud"))
        try Data("{}".utf8).write(to: h.inbox.appendingPathComponent(EntryIndex.fileName))
        try Data().write(to: h.inbox.appendingPathComponent(".DS_Store"))
        try Data().write(to: h.inbox.appendingPathComponent("notes.pdf"))

        let scan = InboxScanner().scan(h.inbox)
        #expect(scan.ready.isEmpty)
        #expect(scan.notDownloaded.map(\.lastPathComponent) == ["IMG_1.jpg"])
    }

    @Test func aDamagedManifestIsLeftAloneNotDeleted() async throws {
        let h = try makeHarness()
        let folder = h.inbox.appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: folder.appendingPathComponent(Capture.manifestName))
        _ = try photo(in: folder)

        _ = await h.drainer.drain(h.inbox)
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: - Routing

    @Test func aChosenDayGoesToThatDaysLatestEntry() async throws {
        let h = try makeHarness()
        let older = try h.store.createDraft(entryDate: day)
        try h.store.updateRawText("morning", for: older)
        let newer = try h.store.createDraft(entryDate: day)
        try h.store.updateRawText("afternoon", for: newer)

        try CaptureWriter(inbox: h.inbox).write(
            text: "Lizzy called", sources: [], destination: .init(day: day), source: "mac"
        )
        let report = await h.drainer.drain(h.inbox)

        #expect(report.filed.entryIds == [newer.id])
        #expect(try h.store.draft(id: newer.id)?.content.rawText == "afternoon\n\nLizzy called")
        #expect(try h.store.drafts(on: day).count == 2)
    }

    @Test func aChosenEntryWinsAndANewEntryIsMadeWhenAsked() async throws {
        let h = try makeHarness()
        let target = try h.store.createDraft(entryDate: CalendarDay(rawValue: "2026-01-01")!)
        let writer = CaptureWriter(inbox: h.inbox)
        try writer.write(text: "to the chosen one", sources: [],
                         destination: .init(day: day, entryId: target.id), source: "share")
        try writer.write(text: "a fresh page", sources: [],
                         destination: .init(day: day, newEntry: true), source: "mac")
        _ = await h.drainer.drain(h.inbox)

        #expect(try h.store.draft(id: target.id)?.content.rawText == "to the chosen one")
        let onDay = try h.store.drafts(on: day)
        #expect(onDay.count == 1)
        #expect(onDay.first?.content.rawText == "a fresh page")
    }

    @Test func aDeletedEntryFallsBackToItsDay() async throws {
        let h = try makeHarness()
        try CaptureWriter(inbox: h.inbox).write(
            text: "still kept", sources: [], destination: .init(day: day, entryId: UUID()), source: "share"
        )
        _ = await h.drainer.drain(h.inbox)
        #expect(try h.store.drafts(on: day).first?.content.rawText == "still kept")
    }

    @Test func aNoteGoesToItsChosenDayWhilePhotosGoByDateTaken() async throws {
        let h = try makeHarness()
        // A photo with no capture date in it, like most screenshots, goes with the note.
        try CaptureWriter(inbox: h.inbox).write(
            text: "Aidan's recital", sources: [try .init(url: photo(in: h.scratch), kind: .photo)],
            destination: .init(day: day, mediaByCaptureDate: true), source: "mac"
        )
        _ = await h.drainer.drain(h.inbox)
        let entries = try h.store.drafts(on: day)
        #expect(entries.count == 1)
        #expect(entries.first?.content.rawText == "Aidan's recital")
        #expect(entries.first?.media.count == 1)
    }

    @Test func aManifestFromBeforeMediaByCaptureDateStillReads() throws {
        let json = #"{"version":1,"id":"9DB16620-C4A0-498C-AC2E-1A1746F73600","createdAt":"2026-10-27T16:58:42Z","destination":{"newEntry":false},"files":[],"source":"mac","text":"test"}"#
        let capture = try JSONDecoder.capture.decode(Capture.self, from: Data(json.utf8))
        #expect(capture.destination.filesByCaptureDate)
        #expect(capture.text == "test")
    }

    // MARK: - Arranged by day

    @Test func undatedPhotosAreGroupedNotFiledAsToday() {
        let monday = CalendarDay(rawValue: "2026-03-09")!
        var plan = CapturePlan(today: day)
        let a = UUID(), b = UUID(), c = UUID()
        plan.place(a, on: nil, today: day)
        plan.place(b, on: day)
        plan.place(c, on: nil, today: day)
        #expect(plan.days.count == 2, "undated stays apart from a real today")
        #expect(plan.days.first?.undated == true, "shown first so it's noticed")
        #expect(plan.days.first?.fileIds == [a, c])

        plan.move(a, to: monday)
        #expect(plan.days.first { $0.day == monday }?.fileIds == [a])
        plan.move(c, to: day)
        #expect(!plan.days.contains { $0.undated }, "the emptied undated group goes away")
        #expect(plan.days.first { $0.day == day }?.fileIds == [b, c])
    }

    @Test func datingTheUndatedGroupJoinsAnExistingDay() {
        let monday = CalendarDay(rawValue: "2026-03-09")!
        var plan = CapturePlan(today: day)
        let a = UUID(), b = UUID()
        plan.place(a, on: monday)
        plan.place(b, on: nil, today: day)
        let undated = plan.days.first { $0.undated }!.id
        plan.setDay(monday, for: undated)
        #expect(plan.days.count == 1)
        #expect(plan.days.first?.fileIds == [a, b])
    }

    @Test func aTitleNamesANewEntryButNeverRenamesOne() async throws {
        let h = try makeHarness()
        let titled = try h.store.createDraft(entryDate: day)
        titled.updateTitle("Already named")
        try h.store.flush()
        let monday = CalendarDay(rawValue: "2026-03-09")!

        var plan = CapturePlan(today: day)
        plan[plan.days[0].id]?.text = "Lunch by the water"
        plan[plan.days[0].id]?.title = "WWWT 3/14/26"
        let other = plan.addDay(monday)
        plan[other]?.text = "Quiet day"
        plan[other]?.title = "  WWWT 3/9/26 "
        #expect(plan.groups.last?.title == "WWWT 3/9/26", "trimmed")
        try CaptureWriter(inbox: h.inbox).write(plan: plan, sources: [], source: "test")
        _ = await h.drainer.drain(h.inbox)

        let drafts = try h.store.allDrafts()
        #expect(drafts.first { $0.id == titled.id }?.content.title == "Already named")
        #expect(drafts.first { $0.entryDate == monday }?.content.title == "WWWT 3/9/26")
    }

    @Test func theSuggestedPrefixIsLearned() {
        #expect(TitleSuggestion.prefix(from: ["Day 1/2/26", "Day 1/3/26", "WWWT 1/4/26", "Trip"]) == "Day")
        #expect(TitleSuggestion.prefix(from: []) == "WWWT")
        #expect(TitleSuggestion.title(prefix: "WWWT", day: day) == "WWWT 3/14/26")
    }

    @Test func photosSortIntoTheirDaysAndNotesCanGoAnywhere() {
        let monday = CalendarDay(rawValue: "2026-03-09")!
        var plan = CapturePlan(today: day)
        let a = UUID(), b = UUID(), c = UUID()
        plan.place(a, on: monday)          // takes over the empty starting day
        plan.place(b, on: day)
        plan.place(c, on: monday)
        #expect(plan.days.map(\.day) == [day, monday], "newest first")
        #expect(plan.days.last?.fileIds == [a, c])

        let extra = plan.addDay(CalendarDay(rawValue: "2026-01-01")!)
        plan[extra]?.text = "  New year walk  "
        plan.remove(file: b)
        #expect(plan.groups.count == 2, "the emptied day drops out")
        #expect(plan.groups.last?.text == "New year walk")
    }

    @Test func latestShowsAsThatDaysNewestEntryOrNew() {
        let newest = EntryIndex.Entry(id: UUID(), day: day, title: "Idea", updatedAt: Date())
        let older = EntryIndex.Entry(id: UUID(), day: day, title: "Morning", updatedAt: .distantPast)
        #expect(CapturePlan.EntryChoice.latest.shown(among: [newest, older]) == .existing(newest.id))
        #expect(CapturePlan.EntryChoice.latest.shown(among: []) == .new)
        #expect(CapturePlan.EntryChoice.new.shown(among: [newest]) == .new)
    }

    @Test func aCaptureArrangedByDayFilesEachDaySeparately() async throws {
        let h = try makeHarness()
        let monday = CalendarDay(rawValue: "2026-03-09")!
        let existing = try h.store.createDraft(entryDate: monday)
        try h.store.updateRawText("started already", for: existing)

        var plan = CapturePlan(today: day)
        let photo1 = UUID(), photo2 = UUID()
        plan.place(photo1, on: day)
        plan.place(photo2, on: monday)
        let todayId = try #require(plan.days.first { $0.day == day }?.id)
        let mondayId = try #require(plan.days.first { $0.day == monday }?.id)
        plan[todayId]?.text = "Pi day"
        plan[todayId]?.entry = .new
        plan[mondayId]?.text = "Forgot this"
        let lone = plan.addDay(CalendarDay(rawValue: "2026-02-02")!)
        plan[lone]?.text = "Groundhog day"

        try CaptureWriter(inbox: h.inbox).write(
            plan: plan,
            sources: [
                .init(url: try photo(in: h.scratch, named: "a.jpg"), kind: .photo, id: photo1),
                .init(url: try photo(in: h.scratch, named: "b.jpg"), kind: .photo, id: photo2),
            ],
            source: "mac"
        )
        let ready = try #require(InboxScanner().scan(h.inbox).ready.first)
        let ingestor = CaptureIngestor(store: h.store, fileStore: h.files)
        let outcome = try await ingestor.ingest(ready)
        _ = try await ingestor.ingest(ready)  // a retry changes nothing

        #expect(outcome.jots == 3)
        #expect(outcome.photos == 2)
        // The digest says exactly what went where.
        #expect(outcome.added[existing.id]?.notes == ["Forgot this"])
        #expect(outcome.added[existing.id]?.mediaIds == [photo2])
        #expect(outcome.added.count == 3)
        let mondayEntry = try #require(try h.store.draft(id: existing.id))
        #expect(mondayEntry.content.rawText == "started already\n\nForgot this")
        #expect(mondayEntry.media.map(\.id) == [photo2])
        let pi = try h.store.drafts(on: day)
        #expect(pi.count == 1)
        #expect(pi.first?.content.rawText == "Pi day")
        #expect(pi.first?.media.map(\.id) == [photo1])
        #expect(try h.store.drafts(on: CalendarDay(rawValue: "2026-02-02")!).first?.content.rawText == "Groundhog day")
    }

    @Test func looseFilesInTheFolderAreFiledToo() async throws {
        let h = try makeHarness()
        _ = try photo(in: h.inbox, named: "Screenshot 2026-03-14 at 9.41.12.png")
        try "remember the milk".write(to: h.inbox.appendingPathComponent("idea.txt"), atomically: true, encoding: .utf8)

        let report = await h.drainer.drain(h.inbox)
        #expect(report.filed.photos == 1)
        #expect(report.filed.jots == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.inbox.path).isEmpty)
        let all = try h.store.allDrafts()
        #expect(all.flatMap(\.media).count == 1)
        #expect(all.contains { $0.content.rawText == "remember the milk" })
    }

    // MARK: - Interruption

    @Test func rerunningAfterADeleteFailedFilesNothingTwice() async throws {
        let h = try makeHarness()
        let source = try photo(in: h.scratch)
        let capture = try CaptureWriter(inbox: h.inbox).write(
            text: "once", sources: [.init(url: source, kind: .photo)],
            destination: .init(day: day), source: "mac"
        )
        let folder = h.inbox.appendingPathComponent(capture.id.uuidString.lowercased())
        let ready = try #require(InboxScanner().scan(h.inbox).ready.first)

        // Filed, then the app died before recording or deleting anything.
        let ingestor = CaptureIngestor(store: h.store, fileStore: h.files)
        _ = try await ingestor.ingest(ready)
        #expect(FileManager.default.fileExists(atPath: folder.path))

        let report = await h.drainer.drain(h.inbox)
        #expect(report.filed.isEmpty)
        let entries = try h.store.drafts(on: day)
        #expect(entries.count == 1)
        #expect(entries[0].content.rawText == "once")
        #expect(entries[0].media.count == 1)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func aNewEntryRetriedAfterACrashIsTheSameEntry() async throws {
        let h = try makeHarness()
        try CaptureWriter(inbox: h.inbox).write(
            text: "new page", sources: [try .init(url: photo(in: h.scratch), kind: .photo)],
            destination: .init(day: day, newEntry: true), source: "mac"
        )
        let ready = try #require(InboxScanner().scan(h.inbox).ready.first)
        let ingestor = CaptureIngestor(store: h.store, fileStore: h.files)
        _ = try await ingestor.ingest(ready)
        _ = try await ingestor.ingest(ready)
        #expect(try h.store.drafts(on: day).count == 1)
    }

    @Test func aFiledJotTheyEditedAwayDoesNotComeBack() async throws {
        let h = try makeHarness()
        let capture = try CaptureWriter(inbox: h.inbox).write(
            text: "typo'd thing", sources: [], destination: .init(day: day), source: "mac"
        )
        let ready = try #require(InboxScanner().scan(h.inbox).ready.first)
        _ = try await CaptureIngestor(store: h.store, fileStore: h.files).ingest(ready)
        h.ledger.record(capture.id)  // filed and recorded, but the delete didn't happen

        let draft = try #require(try h.store.drafts(on: day).first)
        try h.store.updateRawText("fixed thing", for: draft)

        _ = await h.drainer.drain(h.inbox)
        #expect(try h.store.draft(id: draft.id)?.content.rawText == "fixed thing")
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.inbox.path).isEmpty)
    }

    @Test func looseFileIdsAreStableAcrossScans() throws {
        let h = try makeHarness()
        _ = try photo(in: h.inbox)
        let a = InboxScanner().scan(h.inbox).ready.first?.capture
        let b = InboxScanner().scan(h.inbox).ready.first?.capture
        #expect(a != nil)
        #expect(a?.id == b?.id)
        #expect(a?.files.first?.id == b?.files.first?.id)
    }

    // MARK: - Entry index

    @Test func entryIndexRoundTripsAndListsTheDaysEntries() throws {
        let h = try makeHarness()
        let draft = try h.store.createDraft(entryDate: CalendarDay.today())
        try h.store.updateRawText("A long walk by the river\nand more", for: draft)

        let url = h.scratch.appendingPathComponent(EntryIndex.fileName)
        try EntryIndex.make(from: h.store).write(to: url)
        let read = try #require(EntryIndex.read(from: url))
        #expect(read.entries(on: .today()).map(\.title) == ["A long walk by the river"])
    }
}
