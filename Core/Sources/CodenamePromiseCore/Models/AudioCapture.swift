import Foundation
import SwiftData

/// A recorded dictation chunk, persisted to disk *before* any transcription is attempted.
///
/// This model exists because the original spec had nowhere to put it. `POST /stt` took
/// audio and returned a transcript, but the audio itself lived only in a buffer — so
/// "record ten minutes, lose the connection, lose the reflection" was not just possible,
/// it was the default. That is the exact failure the project was founded to eliminate.
/// See ADR-002.
///
/// Audio is a first-class durable artifact with its own lifecycle (record → transcribe →
/// release), which is why it is not a `MediaItem`: photos are attached and kept forever,
/// dictation audio is scaffolding that gets torn down once its transcript is safe.
@Model
public final class AudioCapture {
    public private(set) var id: UUID = UUID()
    public private(set) var recordedAt: Date = Date()

    /// Relative to the media root — same discipline as `MediaItem`. See ADR-007.
    public private(set) var relativePath: String = ""
    public private(set) var durationSeconds: Double = 0
    public private(set) var sizeBytes: Int = 0

    /// Long dictations are recorded in chunks so a failure costs one chunk rather than the
    /// whole session. Chunks transcribe independently and append in this order.
    public var chunkIndex: Int = 0

    public private(set) var transcriptionStatusRaw: String = TranscriptionStatus.pending.rawValue

    /// Kept after transcription until the text has been merged into the draft and saved.
    public var transcript: String?

    /// Lease field, same purpose as `MediaItem.uploadStartedAt`. See ADR-004.
    public var transcriptionStartedAt: Date?
    public var transcriptionAttemptCount: Int = 0
    public var transcriptionError: String?

    /// Earliest time a retry should be attempted, so a persistently failing item backs off
    /// instead of burning battery. Nil means "eligible now".
    public var nextTranscriptionAttemptAt: Date?

    /// Set once the transcript has been appended to the draft's `rawText` *and* that write
    /// has been committed. Only then is the audio file safe to delete.
    public var mergedIntoDraftAt: Date?

    @Relationship public var draft: EntryDraft?

    public init(
        id: UUID = UUID(),
        relativePath: String,
        durationSeconds: Double,
        sizeBytes: Int,
        recordedAt: Date = Date()
    ) {
        self.id = id
        self.relativePath = relativePath
        self.durationSeconds = durationSeconds
        self.sizeBytes = sizeBytes
        self.recordedAt = recordedAt
    }

    public var transcriptionStatus: TranscriptionStatus {
        get { TranscriptionStatus(rawValue: transcriptionStatusRaw) ?? .pending }
        set { transcriptionStatusRaw = newValue.rawValue }
    }

    public func markTranscribing(now: Date = Date()) {
        transcriptionStatus = .transcribing
        transcriptionStartedAt = now
        transcriptionAttemptCount += 1
        transcriptionError = nil
    }

    public func markTranscribed(_ text: String) {
        transcript = text
        transcriptionStatus = .transcribed
        transcriptionStartedAt = nil
        transcriptionError = nil
        nextTranscriptionAttemptAt = nil
    }

    public func markTranscriptionFailed(_ message: String, nextAttemptAt: Date? = nil) {
        transcriptionStatus = .failed
        transcriptionStartedAt = nil
        transcriptionError = message
        nextTranscriptionAttemptAt = nextAttemptAt
    }

    /// Whether a retry is due. A `nil` next-attempt time means eligible immediately.
    public func isTranscriptionDue(now: Date = Date()) -> Bool {
        switch transcriptionStatus {
        case .transcribed, .transcribing:
            return false
        case .pending, .failed:
            guard let next = nextTranscriptionAttemptAt else { return true }
            return now >= next
        }
    }

    public func isTranscriptionStale(now: Date = Date(), timeout: TimeInterval) -> Bool {
        guard transcriptionStatus == .transcribing, let started = transcriptionStartedAt else {
            return false
        }
        return now.timeIntervalSince(started) > timeout
    }

    /// Audio may only be released once its words are durably part of the draft.
    public var isSafeToDelete: Bool { mergedIntoDraftAt != nil }

    public var ownedRelativePaths: [String] {
        relativePath.isEmpty ? [] : [relativePath]
    }
}
