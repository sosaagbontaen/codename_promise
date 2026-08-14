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
        [relativePath, compressedRelativePath].compactMap { $0 }.filter { !$0.isEmpty }
    }
}
