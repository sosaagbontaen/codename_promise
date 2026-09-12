import Foundation
import SwiftData

/// A photo or video attached to an entry.
///
/// The important field here is `relativePath`. The original spec stored an
/// `originalPath` — an absolute URL, typically the transient one handed over by
/// `PhotosPicker`. That loses data two different ways: the temp file is purged out from
/// under you, and absolute container paths break on restore-from-backup because the app
/// container UUID changes. Media bytes are copied into the app container on attach and
/// referenced *relatively* thereafter. See ADR-007 and `MediaFileStore`.
@Model
public final class MediaItem {
    public private(set) var id: UUID = UUID()
    public private(set) var createdAt: Date = Date()

    /// Path relative to the media root, e.g. `"media/<uuid>/original.heic"`.
    /// Never store an absolute path.
    public private(set) var relativePath: String = ""
    public private(set) var originalSizeBytes: Int = 0

    public var compressedRelativePath: String?
    public var compressedSizeBytes: Int?

    /// The pieces a long video was cut into, in order, when no single file could hold it.
    ///
    /// A destination that caps individual files cannot take a four-minute clip at any
    /// watchable bitrate. It can take four one-minute clips. These are those — derived files
    /// like `compressedRelativePath`, and like it the original the user attached is never
    /// replaced (invariant 5). Empty for every video that fitted, which is most of them.
    public var partRelativePaths: [String] = []

    /// Explicit display order. Do not rely on the relationship array's order. See ADR-011.
    public var sortIndex: Int = 0

    // Stored as raw strings; see Enums.swift for why.
    public private(set) var kindRaw: String = MediaKind.photo.rawValue
    public private(set) var compressionLevelRaw: String = CompressionLevel.none.rawValue
    public private(set) var compressionStatusRaw: String = CompressionStatus.pending.rawValue
    public private(set) var uploadStatusRaw: String = UploadStatus.pending.rawValue

    /// Set when an upload begins so a process death can be detected and recovered from
    /// rather than leaving the item stuck in `.uploading` forever. See ADR-004.
    public var uploadStartedAt: Date?
    public var uploadAttemptCount: Int = 0
    public var uploadError: String?

    @Relationship public var draft: EntryDraft?

    public init(
        id: UUID = UUID(),
        kind: MediaKind,
        relativePath: String,
        originalSizeBytes: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.relativePath = relativePath
        self.originalSizeBytes = originalSizeBytes
        self.createdAt = createdAt
    }

    // MARK: - Bridged enums

    public var kind: MediaKind {
        get { MediaKind(rawValue: kindRaw) ?? .photo }
        set { kindRaw = newValue.rawValue }
    }

    public var compressionLevel: CompressionLevel {
        get { CompressionLevel(rawValue: compressionLevelRaw) ?? .none }
        set { compressionLevelRaw = newValue.rawValue }
    }

    public var compressionStatus: CompressionStatus {
        get { CompressionStatus(rawValue: compressionStatusRaw) ?? .pending }
        set { compressionStatusRaw = newValue.rawValue }
    }

    public var uploadStatus: UploadStatus {
        get { UploadStatus(rawValue: uploadStatusRaw) ?? .pending }
        set { uploadStatusRaw = newValue.rawValue }
    }

    // MARK: - Lifecycle

    /// The bytes a destination should receive: the compressed version if we made one,
    /// otherwise the original.
    public var pathForUpload: String { compressedRelativePath ?? relativePath }

    /// Every file this item sends, in order. One for almost everything; several for a video
    /// that had to be cut up to fit.
    ///
    /// Callers upload this rather than `pathForUpload` so that splitting stays invisible to
    /// the sync path — it is a list of files either way.
    public var pathsForUpload: [String] {
        partRelativePaths.isEmpty ? [pathForUpload] : partRelativePaths
    }

    /// True when this item arrives at the destination as several files.
    public var isSplit: Bool { partRelativePaths.count > 1 }

    /// True when there is no version of this the destination would take.
    ///
    /// Worth asking *before* uploading. The old path fell back to the untouched original
    /// whenever compression failed, which meant pushing 200 MB up a phone connection for the
    /// sole purpose of being rejected — the exact round trip ADR-015 exists to avoid.
    public var isTooLargeToSend: Bool { compressionStatus == .tooLargeToSend }

    public func markTooLargeToSend() {
        compressionStatus = .tooLargeToSend
        compressionLevel = .none
    }

    public func markSplit(into paths: [String], totalBytes: Int, level: CompressionLevel) {
        partRelativePaths = paths
        compressedSizeBytes = totalBytes
        compressionLevel = level
        compressionStatus = .compressed
    }

    public var effectiveSizeBytes: Int { compressedSizeBytes ?? originalSizeBytes }

    public func markCompressed(relativePath: String, sizeBytes: Int, level: CompressionLevel) {
        compressedRelativePath = relativePath
        compressedSizeBytes = sizeBytes
        compressionLevel = level
        compressionStatus = .compressed
    }

    public func markCompressionSkipped() {
        compressionStatus = .skipped
        compressionLevel = .none
    }

    public func markUploading(now: Date = Date()) {
        uploadStatus = .uploading
        uploadStartedAt = now
        uploadAttemptCount += 1
        uploadError = nil
    }

    public func markUploaded() {
        uploadStatus = .uploaded
        uploadStartedAt = nil
        uploadError = nil
    }

    public func markUploadFailed(_ message: String) {
        uploadStatus = .failed
        uploadStartedAt = nil
        uploadError = message
    }

    /// True when an upload claims to be in flight but the process that owned it is gone.
    public func isUploadStale(now: Date = Date(), timeout: TimeInterval) -> Bool {
        guard uploadStatus == .uploading, let started = uploadStartedAt else { return false }
        return now.timeIntervalSince(started) > timeout
    }

    /// All file paths this item owns, for cleanup when it is detached or its draft is
    /// deleted. Cascade delete removes the row; these bytes need removing explicitly.
    public var ownedRelativePaths: [String] {
        // The parts count: they are files this item made and nothing else refers to, so
        // leaving them out would strand a few megabytes per split video on every delete.
        // See ADR-018a.
        ([relativePath, compressedRelativePath].compactMap { $0 } + partRelativePaths)
            .filter { !$0.isEmpty }
    }
}
