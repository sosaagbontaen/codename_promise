import Foundation
import SwiftData

/// The models exactly as v2 shipped them.
///
/// Frozen because `SchemaV2` used to point at the live classes, which was correct only while
/// it was the newest version. The moment v3 exists, a version still naming the live types
/// describes whatever those types happen to say today, which is to say nothing — and two
/// versions describing an identical shape hash identically, which Core Data rejects outright
/// with `Duplicate version checksums detected`. That is not hypothetical; it happened when
/// v2 was introduced. See `SchemaV1Models.swift`, where rule 4 is written in blood.
///
/// **Copied from the live models, attribute by attribute, not from the doc comment above
/// them.** Writing down what a schema *ought* to contain is how this went wrong the first two
/// times: SwiftData matches a store to a version by checksum, so a plausible shape that is off
/// by one attribute fails exactly as loudly as no shape at all.
///
/// Relative to v3, v2 is missing precisely two things, both on `EntryDraft`:
///
/// - `organisedJSON`
/// - `organiserVersion`
///
/// Both are plain scalars with defaults, which is what keeps the migration lightweight. They
/// are deliberately *not* inside `EntryContent`: that is a `Codable` composite and SwiftData
/// flattens it into one column per property, so adding a field there is a schema change that
/// fails validation on a non-optional. That cost two days once already (ADR-008a).
extension SchemaV2 {

    @Model
    public final class EntryDraft {
        public var id: UUID = UUID()
        public var createdAt: Date = Date()
        public var updatedAt: Date = Date()
        public var entryDateKey: String = CalendarDay.today().rawValue
        public var content: EntryContent = EntryContent()
        public var formattedTextEditedByUser: Bool = false

        @Relationship(deleteRule: .cascade, inverse: \SchemaV2.MediaItem.draft)
        public var media: [SchemaV2.MediaItem] = []

        @Relationship(deleteRule: .cascade, inverse: \SchemaV2.AudioCapture.draft)
        public var audioCaptures: [SchemaV2.AudioCapture] = []

        @Relationship(deleteRule: .cascade, inverse: \SchemaV2.SyncState.draft)
        public var syncStates: [SchemaV2.SyncState] = []

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

        @Relationship public var draft: SchemaV2.EntryDraft?

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

        @Relationship public var draft: SchemaV2.EntryDraft?

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

        @Relationship public var draft: SchemaV2.EntryDraft?

        public init(id: UUID = UUID()) {
            self.id = id
        }
    }
}
