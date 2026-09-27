import Foundation
import Testing

@testable import CodenamePromiseCore

/// A bulk import that survives being interrupted.
///
/// The failure being fixed: five hundred photos, the phone auto-locks partway, iOS reclaims
/// the app, and reopening it lands on the entry list with the import gone. Most of what is
/// below is about the resume — that every photo ends up in the journal exactly once, and in
/// the entry the person was shown, however many times the import is stopped and started.
@Suite("Resumable photo import")
@MainActor
struct ImportSessionTests {

    private struct Harness {
        let store: DraftStore
        let files: MediaFileStore
        let sessions: ImportSessionStore
        let root: URL
    }

    private func makeHarness() throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-import-\(UUID().uuidString)", isDirectory: true)
        let media = root.appendingPathComponent("media", isDirectory: true)
        let imports = root.appendingPathComponent("imports", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        return Harness(
            store: DraftStore(container: try ModelContainerFactory.makeInMemoryContainer()),
            files: MediaFileStore(root: media),
            sessions: ImportSessionStore(root: imports),
            root: root
        )
    }

    private let tuesday = Date(timeIntervalSince1970: 1_757_400_000)          // one day
    private var wednesday: Date { tuesday.addingTimeInterval(86_400) }        // the next

    /// Stages `count` photos taken on `date`, as the picker would.
    @discardableResult
    private func stage(
        _ count: Int, on date: Date?, into session: inout ImportSession, _ h: Harness
    ) throws -> [ImportSession.Item] {
        var made: [ImportSession.Item] = []
        for index in 0..<count {
            let id = UUID()
            let received = h.root.appendingPathComponent("received-\(id).jpg")
            try Data(repeating: UInt8(index % 255), count: 64).write(to: received)
            let filename = try h.sessions.adopt(fileAt: received, id: id, into: session)
            let item = ImportSession.Item(
                id: id, filename: filename, kind: .photo,
                capturedAt: date?.addingTimeInterval(Double(index))
            )
            session.items.append(item)
            made.append(item)
        }
        try h.sessions.save(session)
        return made
    }

    private func attachedCount(_ h: Harness) throws -> Int {
        try h.store.allDrafts().reduce(0) { $0 + $1.media.count }
    }

    // MARK: - The happy path

    @Test("each day's photos land in one new entry for that day")
    func appliesByDay() async throws {
        let h = try makeHarness()
        var session = ImportSession(requested: 5)
        try h.sessions.prepare(session)
        try stage(3, on: tuesday, into: &session, h)
        try stage(2, on: wednesday, into: &session, h)

        session.freezePlan { _ in [] }
        let outcome = try await ImportApplier(
            store: h.store, fileStore: h.files, sessions: h.sessions
        ).apply(&session)

        #expect(outcome.attached == 5)
        #expect(outcome.entriesMade == 2, "one entry per day, not one per photo")
        #expect(try h.store.allDrafts().map(\.media.count).sorted() == [2, 3])
        #expect(session.remaining.isEmpty)
    }

    // MARK: - Being interrupted

    /// The one this whole change exists for.
    @Test("an import stopped partway and started again attaches every photo exactly once")
    func resumesWithoutDuplicating() async throws {
        let h = try makeHarness()
        var session = ImportSession(requested: 6)
        try h.sessions.prepare(session)
        let photos = try stage(6, on: tuesday, into: &session, h)
        session.freezePlan { _ in [] }

        // The first run gets three photos in before the app is reclaimed. The third was
        // attached but the process died before the plan could record it — the case where
        // a naive resume attaches it a second time.
        let draft = try h.store.createDraft(entryDate: CalendarDay(date: tuesday))
        session.createdDrafts[session.groupId(of: photos[0])] = draft.id
        for (index, photo) in photos.prefix(3).enumerated() {
            _ = try h.store.attachMedia(
                from: h.sessions.url(for: photo, in: session), kind: .photo,
                to: draft, fileStore: h.files, id: photo.id
            )
            if index < 2 {
                session.items[index].applied = true
            }
        }
        try h.sessions.save(session)

        // Relaunch: read the plan back from disk, as the app does, and carry on.
        var resumed = try #require(h.sessions.current())
        let outcome = try await ImportApplier(
            store: h.store, fileStore: h.files, sessions: h.sessions
        ).apply(&resumed)

        #expect(try attachedCount(h) == 6, "six photos picked, six in the journal")
        #expect(outcome.attached == 3, "only the three the first run never reached")
        #expect(Set(draft.media.map(\.id)) == Set(photos.map(\.id)))
    }

    @Test("a resumed import adds to the entry it already made instead of making another")
    func doesNotMakeASecondEntry() async throws {
        let h = try makeHarness()
        var session = ImportSession(requested: 4)
        try h.sessions.prepare(session)
        let photos = try stage(4, on: tuesday, into: &session, h)
        session.freezePlan { _ in [] }

        // The first run made the entry, attached one photo, and stopped.
        var first = session
        first.items = Array(session.items)
        let applier = ImportApplier(store: h.store, fileStore: h.files, sessions: h.sessions)
        var partial = first
        partial.items = partial.items.map { item in
            var item = item
            // Pretend only the first was ever going to be reached this run.
            if item.id != photos[0].id { item.planned = .skip }
            return item
        }
        _ = try await applier.apply(&partial)
        #expect(try h.store.allDrafts().count == 1)

        // Resume with the real plan, carrying over what the first run wrote down.
        var resumed = session
        resumed.createdDrafts = partial.createdDrafts
        resumed.items[0].applied = true
        _ = try await applier.apply(&resumed)

        #expect(try h.store.allDrafts().count == 1, "still one Tuesday, not two")
        #expect(try h.store.allDrafts().first?.media.count == 4)
    }

    @Test("running a finished import again changes nothing")
    func applyingTwiceIsHarmless() async throws {
        let h = try makeHarness()
        var session = ImportSession(requested: 3)
        try h.sessions.prepare(session)
        try stage(3, on: tuesday, into: &session, h)
        session.freezePlan { _ in [] }

        let applier = ImportApplier(store: h.store, fileStore: h.files, sessions: h.sessions)
        _ = try await applier.apply(&session)

        // As if the "finished" flag never made it to disk.
        var again = session
        for index in again.items.indices { again.items[index].applied = false }
        let second = try await applier.apply(&again)

        #expect(second.attached == 0)
        #expect(try attachedCount(h) == 3)
    }

    // MARK: - Things going missing

    @Test("a photo whose file is gone is counted, not crashed on and not faked")
    func missingFileIsReported() async throws {
        let h = try makeHarness()
        var session = ImportSession(requested: 2)
        try h.sessions.prepare(session)
        let photos = try stage(2, on: tuesday, into: &session, h)
        try FileManager.default.removeItem(at: h.sessions.url(for: photos[1], in: session))
        session.freezePlan { _ in [] }

        let outcome = try await ImportApplier(
            store: h.store, fileStore: h.files, sessions: h.sessions
        ).apply(&session)

        #expect(outcome.attached == 1)
        #expect(outcome.missing == 1)
        #expect(session.remaining.isEmpty, "and it does not keep retrying a file that is gone")
    }

    @Test("an entry deleted between review and import does not take its photos with it")
    func deletedTargetFallsBackToANewEntry() async throws {
        let h = try makeHarness()
        let target = try h.store.createDraft(entryDate: CalendarDay(date: tuesday))
        var session = ImportSession(requested: 2)
        try h.sessions.prepare(session)
        try stage(2, on: tuesday, into: &session, h)
        session.freezePlan { _ in [target.id] }
        try h.store.delete(target, fileStore: h.files)

        let outcome = try await ImportApplier(
            store: h.store, fileStore: h.files, sessions: h.sessions
        ).apply(&session)

        #expect(outcome.attached == 2)
        #expect(try h.store.allDrafts().count == 1)
    }

    // MARK: - The plan on disk

    @Test("everything chosen in review survives being written down and read back")
    func manifestRoundTrips() throws {
        let h = try makeHarness()
        var session = ImportSession(requested: 3)
        try h.sessions.prepare(session)
        let photos = try stage(3, on: tuesday, into: &session, h)
        let entry = UUID()
        session.phase = .reviewing
        session.groupDestinations["2025-09-09"] = .existingDraft(entry)
        session.itemDestinations[photos[1].id] = .skip
        session.itemDestinations[photos[2].id] = .newDraft
        session.newEntryTitles["2025-09-09"] = "The lake"
        try h.sessions.save(session)

        let back = try #require(h.sessions.current())
        #expect(back == session)
    }

    /// The default for a day depends on how many entries it has, and a half-finished import
    /// may already have made one. Re-deriving the plan on resume could send photos somewhere
    /// other than where the person was shown.
    @Test("the plan is fixed when Import is pressed, not worked out again on resume")
    func planIsFrozen() throws {
        var session = ImportSession()
        session.items = [
            ImportSession.Item(filename: "a.jpg", kind: .photo, capturedAt: tuesday),
        ]
        session.freezePlan { _ in [] }
        #expect(session.items[0].planned == .newDraft)

        // An entry now exists for that day. The frozen plan must not change its mind.
        let recomputed = session.destination(
            for: session.items[0], in: session.groups[0], existingDrafts: [UUID()]
        )
        #expect(recomputed != session.items[0].planned)
        #expect(session.items[0].planned == .newDraft)
    }

    @Test("it can say how many photos it never got to read")
    func countsUnreadPhotos() {
        var session = ImportSession(requested: 500)
        session.items = (0..<147).map { _ in
            ImportSession.Item(filename: "x.jpg", kind: .photo, capturedAt: nil)
        }
        #expect(session.unread == 353)
    }

    @Test("an unreadable manifest is ignored, and its photos are not deleted over it")
    func corruptManifestKeepsPhotos() throws {
        let h = try makeHarness()
        var session = ImportSession(requested: 1)
        try h.sessions.prepare(session)
        let photos = try stage(1, on: tuesday, into: &session, h)
        let manifest = h.sessions.directory(for: session).appendingPathComponent("manifest.json")
        try Data("not json".utf8).write(to: manifest)

        #expect(h.sessions.current() == nil)
        #expect(FileManager.default.fileExists(
            atPath: h.sessions.url(for: photos[0], in: session).path
        ))
    }

    @Test("photos are staged somewhere the system will not empty")
    func stagesOutsideTheTemporaryDirectory() throws {
        let sessions = try ImportSessionStore.makeDefault()
        #expect(!sessions.root.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(sessions.root.path.contains("Application Support"))
    }
}
