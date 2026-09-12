import Foundation
import SwiftData

/// The models exactly as v3 shipped them.
///
/// Frozen because `SchemaV3` used to point at the live classes, which was correct only while
/// it was the newest version. v4 exists now, and a version still naming the live types
/// describes whatever those types happen to say today — two versions describing an identical
/// shape hash identically, which Core Data rejects with `Duplicate version checksums
/// detected`. Rule 4, written in blood in `SchemaV1Models.swift`.
///
/// **Derived from the v2 copy plus exactly what v3 added**, rather than retyped from the live
/// models: v3 is v2 with `EntryDraft.organisedJSON` and `EntryDraft.organiserVersion`, and
/// nothing else. SwiftData matches a store to a version by checksum, so a plausible shape
/// that is off by one attribute fails exactly as loudly as no shape at all.
///
/// Relative to v4, v3 is missing precisely two things, both on `SyncState`:
///
/// - `photoBlockIds`
/// - `videoBlockIds`
///
/// Both are arrays with an empty default, which is what keeps the migration lightweight.
extension SchemaV3 {

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

        @Relationship(deleteRule: .cascade, inverse: \SchemaV3.MediaItem.draft)
        public var media: [SchemaV3.MediaItem] = []

        @Relationship(deleteRule: .cascade, inverse: \SchemaV3.AudioCapture.draft)
        public var audioCaptures: [SchemaV3.AudioCapture] = []

        @Relationship(deleteRule: .cascade, inverse: \SchemaV3.SyncState.draft)
        public var syncStates: [SchemaV3.SyncState] = []

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
        public var kindRaw: String = MediaKind.photo.rawValue
        public var compressionLevelRaw: String = CompressionLevel.none.rawValue
        public var compressionStatusRaw: String = CompressionStatus.pending.rawValue
        public var uploadStatusRaw: String = UploadStatus.pending.rawValue
        public var uploadStartedAt: Date?
        public var uploadAttemptCount: Int = 0
        public var uploadError: String?

        @Relationship public var draft: SchemaV3.EntryDraft?

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

        @Relationship public var draft: SchemaV3.EntryDraft?

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

        @Relationship public var draft: SchemaV3.EntryDraft?

        public init(id: UUID = UUID()) {
            self.id = id
        }
    }
}
