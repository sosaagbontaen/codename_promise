import Foundation

// Every one of these is persisted as its raw `String` on the @Model, with a computed
// property bridging back to the enum. Reason: enum-typed SwiftData properties have been
// unreliable inside `#Predicate`, and the retry/queue queries in this app are exactly
// the predicates that would break. See ADR-012.
//
// The bridging accessors deliberately fall back to a safe default rather than crashing,
// so an unknown value written by a future schema version can never make a draft
// unreadable. Losing a status is recoverable; losing an entry is not.

public enum MediaKind: String, Codable, Sendable, CaseIterable {
    case photo, video

    /// What a file on disk most likely is, for the one caller that has bytes and no picker
    /// to ask: import. Defaults to photo, because a still that turns out to be a video plays
    /// its first frame, while a video row pointing at a JPEG shows a play button over
    /// something that will never play.
    public static func forExtension(_ ext: String) -> MediaKind {
        ["mov", "mp4", "m4v", "avi", "hevc"].contains(ext.lowercased()) ? .video : .photo
    }
}

public enum CompressionLevel: String, Codable, Sendable, CaseIterable {
    case none, low, medium, high
}

/// Compression is tracked separately from upload. The original spec collapsed both into
/// one `uploadStatus`, which made "needs compressing" indistinguishable from "needs
/// uploading" and left any retry pass unable to decide what to do. See ADR-013.
public enum CompressionStatus: String, Codable, Sendable, CaseIterable {
    case pending, compressing, compressed, skipped, failed
}

public enum UploadStatus: String, Codable, Sendable, CaseIterable {
    case pending, uploading, uploaded, failed
}

public enum TranscriptionStatus: String, Codable, Sendable, CaseIterable {
    case pending, transcribing, transcribed, failed
}

public enum SyncTarget: String, Codable, Sendable, CaseIterable {
    case notion, evernote, obsidian
}

public enum SyncStatus: String, Codable, Sendable, CaseIterable {
    case pending, syncing, synced, failed
}

/// Where a multi-step sync got to, so a retry resumes instead of restarting.
/// Restarting is what duplicates content in the destination. See ADR-003 / ADR-005.
/// How far a sync has got, in the order the work is now done.
///
/// The order changed: the words are written before the media. Uploading five photos takes
/// most of a sync, and putting that first meant a failure anywhere in it left a page that had
/// been created and left empty, with the entry's text still only on the phone. Text first
/// means the worst case is an entry whose photos have not arrived yet, which is a page worth
/// having.
///
/// `filesUploaded` is retained and deliberately ranked *below* `contentInserted` even though
/// uploading now happens after it. A store written by an older build may hold that value,
/// meaning "media uploaded, text not yet written", and ranking it above the text would make
/// the resume skip the insert — an entry arriving in Notion with its photos and none of its
/// words. Ranking it low costs a re-check of work already done, and `uploadedFileIds` means
/// nothing is uploaded twice. See ADR-012 on why an unknown value must never make an entry
/// unreadable; the same reasoning applies to a value whose meaning has moved.
public enum SyncPhase: String, Codable, Sendable, CaseIterable {
    case notStarted
    case pageEnsured
    /// Legacy. Written by builds that uploaded media before writing the text.
    case filesUploaded
    case contentInserted
    case photosAttached
    case videosAttached
    case propertiesUpdated

    public var isComplete: Bool { self == .propertiesUpdated }

    /// Ordering used to decide which steps a resume may skip.
    public var rank: Int {
        switch self {
        case .notStarted: 0
        case .filesUploaded: 1
        case .pageEnsured: 2
        case .contentInserted: 3
        case .photosAttached: 4
        case .videosAttached: 5
        case .propertiesUpdated: 6
        }
    }
}
