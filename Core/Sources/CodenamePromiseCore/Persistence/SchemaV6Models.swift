import Foundation
import SwiftData

/// The models exactly as v6 shipped them.
///
/// Frozen because v7 exists. **Derived from the v5 copy plus exactly what v6 added**
/// (`EntryDraft.coverMediaId`), not retyped from the live models. See the note in
/// `SchemaV4Models.swift` for why that matters.
///
/// Relative to v7, v6 is missing precisely one thing, on `EntryDraft`:
///
/// - `coverMediaIds`
///
/// An array with an empty default, which is what keeps the migration lightweight.
extension SchemaV6 {

    @Model
    public final class EntryDraft {
        public var id: UUID = UUID()
        public var createdAt: Date = Date()
        public var updatedAt: Date = Date()
        public var entryDateKey: String = CalendarDay.today().rawValue
        public var content: EntryContent = EntryContent()
        public var formattedTextEditedByUser: Bool = false
        public var organisedJSON: String = ""
        public var organiserVersion: String?
        // What v6 added: one chosen cover photo.
        public var coverMediaId: UUID?

        @Relationship(deleteRule: .cascade, inverse: \SchemaV6.MediaItem.draft)
        public var media: [SchemaV6.MediaItem] = []

        @Relationship(deleteRule: .cascade, inverse: \SchemaV6.AudioCapture.draft)
        public var audioCaptures: [SchemaV6.AudioCapture] = []

        @Relationship(deleteRule: .cascade, inverse: \SchemaV6.SyncState.draft)
        public var syncStates: [SchemaV6.SyncState] = []

        public init(id: UUID = UUID(), createdAt: Date = Date(), entryDateKey: String) {
            self.id = id
            self.createdAt = createdAt
            self.updatedAt = createdAt
            self.entryDateKey = entryDateKey
        }
    }

    @Model
    public final class MediaItem {
        public var id: UUID = UUID()
        public var createdAt: Date = Date()
        public var relativePath: String = ""
        public var originalSizeBytes: Int = 0
        public var compressedRelativePath: String?
        public var compressedSizeBytes: Int?
        public var sortIndex: Int = 0
        // What v5 added: the pieces a long video was cut into.
        public var partRelativePaths: [String] = []
        public var kindRaw: String = MediaKind.photo.rawValue
        public var compressionLevelRaw: String = CompressionLevel.none.rawValue
        public var compressionStatusRaw: String = CompressionStatus.pending.rawValue
        public var uploadStatusRaw: String = UploadStatus.pending.rawValue
        public var uploadStartedAt: Date?
        public var uploadAttemptCount: Int = 0
        public var uploadError: String?

        @Relationship public var draft: SchemaV6.EntryDraft?

        public init(id: UUID = UUID(), relativePath: String) {
            self.id = id
            self.relativePath = relativePath
        }
    }

    @Model
    public final class AudioCapture {
        public var id: UUID = UUID()
        public var recordedAt: Date = Date()
        public var relativePath: String = ""
        public var durationSeconds: Double = 0
        public var sizeBytes: Int = 0
        public var chunkIndex: Int = 0
        public var transcriptionStatusRaw: String = TranscriptionStatus.pending.rawValue
        public var transcript: String?
        public var transcriptionStartedAt: Date?
        public var transcriptionAttemptCount: Int = 0
        public var transcriptionError: String?
        public var nextTranscriptionAttemptAt: Date?
        public var mergedIntoDraftAt: Date?

        @Relationship public var draft: SchemaV6.EntryDraft?

        public init(id: UUID = UUID(), relativePath: String) {
            self.id = id
            self.relativePath = relativePath
        }
    }

    @Model
    public final class SyncState {
        public var id: UUID = UUID()
        public var targetRaw: String = SyncTarget.notion.rawValue
        public var statusRaw: String = SyncStatus.pending.rawValue
        public var phaseRaw: String = SyncPhase.notStarted.rawValue
        public var externalId: String?
        public var syncedContentHash: String?
        public var attemptId: String?
        public var attemptContentHash: String?
        public var uploadedFileIds: [String: String] = [:]
        public var insertedBlockIds: [String] = []
        public var destinationFingerprint: String?
        public var appendsToExistingPage: Bool = false
        public var externalTitle: String?
        public var startedAt: Date?
        public var lastSyncedAt: Date?
        public var lastSyncError: String?
        public var attemptCount: Int = 0

        // What v4 added. The words are written before the media now, in three calls, and the
        // server deletes exactly the block ids it is handed, so each stage tracks its own.
        public var photoBlockIds: [String] = []
        public var videoBlockIds: [String] = []

        @Relationship public var draft: SchemaV6.EntryDraft?

        public init(id: UUID = UUID()) {
            self.id = id
        }
    }
}
