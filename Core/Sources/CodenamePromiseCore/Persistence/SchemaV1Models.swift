import Foundation
import SwiftData

/// The models exactly as v1 shipped them.
///
/// These are frozen copies, not live types, and nothing outside the migration plan should
/// ever touch them. They exist because a `VersionedSchema` has to *describe a shape*, and a
/// version that points at the live classes describes whatever those classes happen to say
/// today — which is to say, nothing.
///
/// That is not a theoretical objection; it was got wrong twice in a row on a device holding
/// real entries:
///
/// 1. Attributes were added to the live models while `SchemaV1` still claimed to describe
///    them. A store written by the older build no longer matched, and SwiftData refused to
///    open it — *"Couldn't open your journal"*.
/// 2. `SchemaV2` was added, pointing at the same four classes as `SchemaV1`. Two versions
///    describing an identical shape hash identically, and Core Data rejects that outright
///    with `NSInvalidArgumentException: Duplicate version checksums detected`.
///
/// **The shape below is not a guess.** It was read out of an actual store — its columns from
/// `PRAGMA table_info`, its stamped version (`1.0.0`) and checksum from `Z_METADATA`. Writing
/// down what v1 *ought* to have been is how this went wrong the first two times: SwiftData
/// matches a store to a version by checksum, so a plausible-looking shape that is off by one
/// attribute fails exactly as loudly as no shape at all.
///
/// Relative to today's models, v1 is missing precisely two things:
///
/// - `SyncState.externalTitle`
/// - `EntryContent.formattedTextEditedByUser`
///
/// That second one is the trap. `EntryContent` is a `Codable` value stored as one attribute,
/// which reads like it should be opaque to the schema — it is not. SwiftData flattens a
/// composite attribute into one column per property (`ZTITLE`, `ZRAWTEXT`, `ZFORMATTEDTEXT`,
/// `ZFORMATTERVERSION`), so **adding a field to `EntryContent` is a schema change** exactly
/// like adding one to a `@Model`. The tolerant `init(from:)` on `EntryContent` protects
/// decoding; it does nothing for the store's checksum.
///
/// The nesting is what keeps the entity names right — SwiftData names entities after the
/// simple type name, so `SchemaV1.EntryDraft` is still the `EntryDraft` entity, which is what
/// lets a lightweight stage map v1 rows onto v2 ones.
///
/// **When you add a schema version:** copy the current models into a new `SchemaVN` namespace
/// *before* changing them, and leave the older namespaces alone forever.
extension SchemaV1 {

    /// `EntryContent` as v1 stored it — without `formattedTextEditedByUser`.
    public struct Content: Codable, Hashable, Sendable {
        public var title: String?
        public var rawText: String = ""
        public var formattedText: String?
        public var formatterVersion: String?

        public init() {}
    }

    @Model
    public final class EntryDraft {
        public var id: UUID = UUID()
        public var createdAt: Date = Date()
        public var updatedAt: Date = Date()
        public var entryDateKey: String = CalendarDay.today().rawValue
        public var content: SchemaV1.Content = SchemaV1.Content()

        @Relationship(deleteRule: .cascade, inverse: \SchemaV1.MediaItem.draft)
        public var media: [SchemaV1.MediaItem] = []

        @Relationship(deleteRule: .cascade, inverse: \SchemaV1.AudioCapture.draft)
        public var audioCaptures: [SchemaV1.AudioCapture] = []

        @Relationship(deleteRule: .cascade, inverse: \SchemaV1.SyncState.draft)
        public var syncStates: [SchemaV1.SyncState] = []

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

        @Relationship public var draft: SchemaV1.EntryDraft?

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

        @Relationship public var draft: SchemaV1.EntryDraft?

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
        public var startedAt: Date?
        public var lastSyncedAt: Date?
        public var lastSyncError: String?
        public var attemptCount: Int = 0

        // Note: no `externalTitle`. That is the one attribute v2 adds here.

        @Relationship public var draft: SchemaV1.EntryDraft?

        public init(id: UUID = UUID()) {
            self.id = id
        }
    }
}
