import Foundation

/// Where a sync has actually got to.
///
/// The fractions are weighted by how long each step really takes rather than split evenly —
/// uploading five photos dominates a sync, and a bar that jumps to 80% and then sits there
/// for a minute is worse than no bar at all. Progress is derived from completed phases, so a
/// stalled sync shows a stalled bar. That is the honest signal.
public enum SyncProgress: Sendable, Equatable {
    case preparing
    case creatingPage
    case findingPage
    case uploading(done: Int, total: Int)
    case writingContent
    case updatingProperties
    case finishing

    private static let pageWeight = 0.15
    private static let uploadWeight = 0.45
    private static let contentWeight = 0.30
    private static let propertiesWeight = 0.10

    public var fraction: Double {
        switch self {
        case .preparing:
            0.02
        case .creatingPage, .findingPage:
            Self.pageWeight
        case .uploading(let done, let total):
            Self.pageWeight + Self.uploadWeight * (total == 0 ? 1 : Double(done) / Double(total))
        case .writingContent:
            Self.pageWeight + Self.uploadWeight
        case .updatingProperties:
            Self.pageWeight + Self.uploadWeight + Self.contentWeight
        case .finishing:
            1.0
        }
    }

    /// Names the step in terms of what is happening to the user's entry, not the API call.
    public var message: String {
        switch self {
        case .preparing:
            "Preparing…"
        case .creatingPage:
            "Creating the page…"
        case .findingPage:
            "Opening the entry…"
        case .uploading(let done, let total):
            total == 1 ? "Uploading photo…" : "Uploading photo \(min(done + 1, total)) of \(total)…"
        case .writingContent:
            "Writing your entry…"
        case .updatingProperties:
            "Finishing up…"
        case .finishing:
            "Done"
        }
    }
}
