import Foundation
import SwiftData
import Testing
@testable import CodenamePromiseCore

/// A long recording that survives the app dying halfway through it.
///
/// The recorder used to stream into a temporary file and only hand the bytes over once the
/// person pressed stop. That meant a ten minute reflection existed nowhere durable for ten
/// minutes: a crash, a force-quit or a jetsam took all of it, and the temporary directory is
/// purgeable by the system besides. Tolerable while dictation was short bursts inside the
/// editor; not tolerable now that talking for ten minutes is the whole product.
///
/// I checked whether a container could simply be made to survive the kill, since that would
/// have avoided cutting the audio up at all. It cannot: an AAC recording killed mid-write
/// leaves the samples on disk with a header claiming zero frames for CAF, and a file that
/// will not open at all for M4A. Neither gives the audio back. So the recording is written in
/// finished chunks, which is what `AudioCapture.chunkIndex` was always for.
@Suite("Chunked recording")
@MainActor
struct ChunkedRecordingTests {

    private func makeFileStore() throws -> MediaFileStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-chunk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return MediaFileStore(root: root)
    }

    /// The recorder needs somewhere durable to stream to *before* it has any bytes.
    @Test("a reserved path exists to be written to, and is relative")
    func reserveMakesRoom() throws {
        let files = try makeFileStore()
        let spot = try files.reserve(preferredName: "dictation", extension: "m4a")

        #expect(!spot.relativePath.hasPrefix("/"))
        #expect(spot.relativePath.hasSuffix(".m4a"))
        #expect(files.url(for: spot.relativePath) == spot.url)
        // The directory is there so a recorder can open the file immediately.
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: spot.url.deletingLastPathComponent().path, isDirectory: &isDirectory
        ))
        #expect(isDirectory.boolValue)
    }

    /// The point of the whole exercise: chunks that finished before the crash are still there
    /// after it, with a row pointing at each one.
    @Test("chunks written before a crash survive the crash")
    func finishedChunksSurvive() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let files = try makeFileStore()
        let draftId: UUID

        // The recording session. Three chunks land; the fourth never finishes because the
        // process dies, which is why nothing here calls stop.
        do {
            let store = DraftStore(container: container)
            let draft = try store.createDraft()
            draftId = draft.id

            for chunk in 0..<3 {
                let spot = try files.reserve(preferredName: "dictation", extension: "m4a")
                let bytes = Data("chunk \(chunk)".utf8)
                try bytes.write(to: spot.url)
                try store.attachAudioCapture(
                    id: spot.id,
                    relativePath: spot.relativePath,
                    sizeBytes: bytes.count,
                    durationSeconds: 60,
                    to: draft
                )
            }
        }

        let reopened = DraftStore(container: container)
        let recovered = try #require(try reopened.draft(id: draftId))
        #expect(recovered.orderedAudioCaptures.count == 3)
        for capture in recovered.orderedAudioCaptures {
            #expect(files.exists(capture.relativePath), "the bytes should still be on disk")
        }
    }

    /// Sentences must come back in the order they were spoken. Left at the default of 0 for
    /// every capture, ordering fell through to sorting by UUID string, which would shuffle a
    /// ten minute recording into nonsense.
    @Test("chunks are ordered by when they were spoken, not by id")
    func chunksKeepSpokenOrder() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let files = try makeFileStore()
        let store = DraftStore(container: container)
        let draft = try store.createDraft()

        var expected: [String] = []
        for chunk in 0..<6 {
            let spot = try files.reserve(preferredName: "dictation", extension: "m4a")
            try Data("x".utf8).write(to: spot.url)
            let capture = try store.attachAudioCapture(
                id: spot.id,
                relativePath: spot.relativePath,
                sizeBytes: 1,
                durationSeconds: 60,
                to: draft
            )
            #expect(capture.chunkIndex == chunk)
            expected.append(capture.relativePath)
        }

        #expect(draft.orderedAudioCaptures.map(\.relativePath) == expected)
    }

    /// The older in-memory path is still used by the editor's dictation button, and it must
    /// take its place in the same running order rather than sitting at zero alongside them.
    @Test("audio handed over as bytes joins the same running order")
    func inMemoryPathAlsoOrders() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let files = try makeFileStore()
        let store = DraftStore(container: container)
        let draft = try store.createDraft()

        let spot = try files.reserve(preferredName: "dictation", extension: "m4a")
        try Data("streamed".utf8).write(to: spot.url)
        try store.attachAudioCapture(
            id: spot.id, relativePath: spot.relativePath,
            sizeBytes: 8, durationSeconds: 30, to: draft
        )

        let second = try store.attachAudioCapture(
            data: Data("in memory".utf8),
            fileExtension: "m4a",
            durationSeconds: 12,
            to: draft,
            fileStore: files
        )
        #expect(second.chunkIndex == 1)
    }

    /// A reserved path nothing ever wrote to must not become a permanent empty directory.
    @Test("a reservation nobody used is reaped")
    func unusedReservationIsReaped() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let files = try makeFileStore()
        let store = DraftStore(container: container)

        let spot = try files.reserve(preferredName: "dictation", extension: "m4a")
        try Data("orphan".utf8).write(to: spot.url)

        let reaped = files.reapOrphans(claimedRelativePaths: try store.claimedRelativePaths())
        #expect(reaped.contains(spot.relativePath))
        #expect(!files.exists(spot.relativePath))
    }
}
