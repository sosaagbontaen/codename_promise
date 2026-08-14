import Foundation
import SwiftData
import Testing
@testable import CodenamePromiseCore

/// Opening a store written by an older build.
///
/// Every other test in this suite starts from `makeInMemoryContainer()` — an empty database
/// already at the current schema. That is a *fresh install*, which is the one situation a
/// real user is never in. Someone journaling for years opens a store written by whatever
/// build they last ran, so every launch after the first is a migration.
///
/// The suite was therefore structurally incapable of catching a migration failure, and duly
/// didn't: attributes were added to the models three times without a version bump, 140 tests
/// stayed green, and the build that reached the phone answered "Couldn't open your journal".
///
/// These tests write a store using the real `SchemaV1` models and open that same file through
/// the real `ModelContainerFactory` and migration plan — the actual thing that happens on the
/// first launch after an update.
@Suite("Migration from an older store")
@MainActor
struct MigrationTests {

    /// Writes a v1-shaped store to disk and returns its URL.
    ///
    /// Built from `SchemaV1`'s own frozen models, so this is genuinely the old shape rather
    /// than the current shape with a smaller version number on it.
    private func makeLegacyStore(entries: Int = 3) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-\(UUID().uuidString).store")

        let schema = Schema(versionedSchema: SchemaV1.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: url)]
        )
        let context = ModelContext(container)

        for index in 0..<entries {
            let draft = SchemaV1.EntryDraft(
                entryDateKey: "2026-08-0\(index + 1)"
            )
            var content = SchemaV1.Content()
            content.title = "Entry \(index)"
            content.rawText = "Something that happened on day \(index)."
            content.formattedText = index == 0 ? "- Something that happened" : nil
            draft.content = content
            context.insert(draft)

            let media = SchemaV1.MediaItem(relativePath: "media/\(index)/original.jpg")
            context.insert(media)
            draft.media.append(media)

            let audio = SchemaV1.AudioCapture(relativePath: "audio/\(index)/take.m4a")
            audio.transcript = "spoken words \(index)"
            context.insert(audio)
            draft.audioCaptures.append(audio)

            let sync = SchemaV1.SyncState()
            sync.externalId = index == 0 ? "page-0" : nil
            sync.syncedContentHash = index == 0 ? "hash-0" : nil
            context.insert(sync)
            draft.syncStates.append(sync)
        }
        try context.save()
        return url
    }

    /// Opens a store the way the app does on launch.
    private func openThroughApp(_ url: URL) throws -> DraftStore {
        DraftStore(container: try ModelContainerFactory.makeAppContainer(url: url))
    }

    // MARK: - The tests

    /// The exact failure that reached the phone: a store from an older build refusing to open.
    @Test("a store written by the previous build still opens")
    func legacyStoreOpens() throws {
        let url = try makeLegacyStore()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try openThroughApp(url).allDrafts().count == 3)
    }

    @Test("nothing the user wrote is lost in the migration")
    func contentSurvives() throws {
        let url = try makeLegacyStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let drafts = try openThroughApp(url).allDrafts()

        #expect(Set(drafts.compactMap(\.content.title)) == ["Entry 0", "Entry 1", "Entry 2"])
        for draft in drafts {
            #expect(draft.content.rawText.hasPrefix("Something that happened"))
        }
        #expect(drafts.contains { $0.content.formattedText == "- Something that happened" })
    }

    @Test("attachments survive, and still point at the same files")
    func relationshipsSurvive() throws {
        let url = try makeLegacyStore()
        defer { try? FileManager.default.removeItem(at: url) }

        for draft in try openThroughApp(url).allDrafts() {
            #expect(draft.orderedMedia.count == 1)
            #expect(draft.orderedMedia[0].relativePath.hasSuffix("original.jpg"))
            #expect(draft.orderedAudioCaptures.count == 1)
        }
    }

    /// An un-merged recording is the most dangerous thing in the store to lose — the words
    /// exist nowhere else yet. See ADR-002.
    @Test("audio waiting to be transcribed comes through a migration")
    func pendingAudioSurvives() throws {
        let url = try makeLegacyStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let captures = try openThroughApp(url).allDrafts().flatMap(\.orderedAudioCaptures)
        #expect(captures.count == 3)
        for capture in captures {
            #expect(capture.mergedIntoDraftAt == nil)
            #expect(capture.transcript?.hasPrefix("spoken words") == true)
            #expect(capture.isSafeToDelete == false)
        }
    }

    /// New attributes must arrive at their declared defaults, not as nulls that trap on read.
    @Test("attributes added after v1 come back as their defaults")
    func newAttributesTakeDefaults() throws {
        let url = try makeLegacyStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let drafts = try openThroughApp(url).allDrafts()
        let states = drafts.flatMap(\.syncStates)

        #expect(!states.isEmpty)
        for state in states {
            #expect(state.appendsToExistingPage == false)
            #expect(state.destinationFingerprint == nil)
            #expect(state.externalTitle == nil)
        }
        for draft in drafts {
            #expect(draft.formattedTextEditedByUser == false)
        }
    }

    /// The trap that made this class of bug survive two attempts at fixing it.
    ///
    /// `EntryContent` is a `Codable` value stored as one attribute, which reads like it
    /// should be opaque to the schema. It is not: SwiftData flattens it into one column per
    /// property, so adding a field to it is a schema change exactly like adding one to a
    /// `@Model`. A non-optional addition fails the migration outright —
    ///
    ///     entity=EntryDraft, attribute=formattedTextEditedByUser,
    ///     reason=Validation error missing attribute values on mandatory destination attribute
    ///
    /// — because a default written in Swift on a property of a composite attribute never
    /// reaches the entity description. `EntryContent.init(from:)` being tolerant does not
    /// help; Core Data validates the column before any decoding happens.
    ///
    /// `SchemaV1.Content` is frozen at the four fields the shipped store actually has, so
    /// this test fails the moment someone adds a fifth non-optional one — which is the only
    /// reason it exists. If it fails, put the property on `EntryDraft` instead.
    @Test("a field added to EntryContent does not make the store unopenable")
    func compositeAttributeStaysMigratable() throws {
        let url = try makeLegacyStore(entries: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        let drafts = try openThroughApp(url).allDrafts()
        let draft = try #require(drafts.first)
        #expect(draft.content.rawText == "Something that happened on day 0.")
        #expect(draft.content.formattedText == "- Something that happened")
    }

    @Test("a page id recorded by the old build is still there afterwards")
    func externalIdSurvives() throws {
        let url = try makeLegacyStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let states = try openThroughApp(url).allDrafts().flatMap(\.syncStates)
        #expect(states.compactMap(\.externalId) == ["page-0"],
                "losing this would orphan the entry's Notion page and sync a duplicate")
        #expect(states.compactMap(\.syncedContentHash) == ["hash-0"],
                "losing this would re-push every entry as though it had never synced")
    }

    /// Migration must not be a one-shot that only works the first time.
    @Test("the migrated store reopens cleanly")
    func migratedStoreReopens() throws {
        let url = try makeLegacyStore()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try openThroughApp(url)
        #expect(try openThroughApp(url).allDrafts().count == 3)
    }

    @Test("writing still works after migrating")
    func canWriteAfterMigration() throws {
        let url = try makeLegacyStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try openThroughApp(url)
        let draft = try store.createDraft()
        try store.updateRawText("written after the migration", for: draft)

        #expect(try store.allDrafts().count == 4)
    }

    /// The guard against the mistake this whole file exists because of. Two versions that
    /// describe the same shape hash identically, and Core Data throws
    /// "Duplicate version checksums detected" — an uncatchable ObjC exception, so the app
    /// doesn't fail to open the store, it terminates.
    @Test("each schema version describes a distinct shape")
    func schemaVersionsAreDistinct() throws {
        var numbers: Set<String> = []
        var shapes: Set<String> = []
        var count = 0

        for version in CodenamePromiseMigrationPlan.schemas {
            count += 1
            numbers.insert("\(version.versionIdentifier)")
            // The type identity of a version's models is what ends up hashed into the
            // checksum Core Data compares, so that is what has to differ.
            var names: [String] = []
            for model in version.models { names.append(String(reflecting: model)) }
            shapes.insert(names.sorted().joined(separator: ","))
        }

        #expect(numbers.count == count, "two schema versions share a version number")
        #expect(shapes.count == count,
                "two schema versions point at the same model types — freeze the older one")
    }
}
