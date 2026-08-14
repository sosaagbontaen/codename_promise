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
public enum SyncPhase: String, Codable, Sendable, CaseIterable {
    case notStarted
    case pageEnsured
    case filesUploaded
    case contentInserted
    case propertiesUpdated

    public var isComplete: Bool { self == .propertiesUpdated }

    /// Ordering used to decide which steps a resume may skip.
    public var rank: Int {
        switch self {
        case .notStarted: 0
        case .pageEnsured: 1
        case .filesUploaded: 2
        case .contentInserted: 3
        case .propertiesUpdated: 4
        }
    }
}
