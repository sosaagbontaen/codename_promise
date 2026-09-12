import Foundation

/// Where a sync has actually got to.
///
/// Named for the stages a person recognises in their own entry — the words, then the photos,
/// then the videos — because that is the order the work is done in and the order somebody
/// waiting wants to hear about. "Uploading" alone left them watching a bar with no idea
/// whether their writing had arrived or whether a video was holding everything up.
///
/// The fractions are weighted by how long each step really takes rather than split evenly.
/// Uploading dominates a sync, and a bar that jumps to 80% and then sits there for a minute
/// is worse than no bar at all. Progress is derived from completed stages, so a stalled sync
/// shows a stalled bar. That is the honest signal.
public enum SyncProgress: Sendable, Equatable {
    case preparing
    case creatingPage
    case findingPage
    case writingText
    case uploadingPhotos(done: Int, total: Int)
    case attachingPhotos
    case uploadingVideos(done: Int, total: Int)
    case attachingVideos
    case updatingProperties
    case finishing

    private static let pageWeight = 0.10
    private static let textWeight = 0.15
    private static let photoWeight = 0.30
    private static let videoWeight = 0.35
    private static let propertiesWeight = 0.10

    private static let beforePhotos = pageWeight + textWeight
    private static let beforeVideos = beforePhotos + photoWeight

    public var fraction: Double {
        switch self {
        case .preparing:
            0.02
        case .creatingPage, .findingPage:
            Self.pageWeight
        case .writingText:
            Self.pageWeight
        case .uploadingPhotos(let done, let total):
            Self.beforePhotos
                + Self.photoWeight * (total == 0 ? 1 : Double(done) / Double(total))
        case .attachingPhotos:
            Self.beforeVideos
        case .uploadingVideos(let done, let total):
            Self.beforeVideos
                + Self.videoWeight * (total == 0 ? 1 : Double(done) / Double(total))
        case .attachingVideos, .updatingProperties:
            Self.beforeVideos + Self.videoWeight
        case .finishing:
            1.0
        }
    }

    /// Names the step in terms of what is happening to the user's entry, not the API call.
    public var message: String {
        switch self {
        case .preparing:
            "Getting ready\u{2026}"
        case .creatingPage:
            "Making the page\u{2026}"
        case .findingPage:
            "Opening the entry\u{2026}"
        case .writingText:
            "Sending your words\u{2026}"
        case .uploadingPhotos(let done, let total):
            total == 1 ? "Sending your photo\u{2026}"
                       : "Sending photo \(min(done + 1, total)) of \(total)\u{2026}"
        case .attachingPhotos:
            "Adding the photos\u{2026}"
        case .uploadingVideos(let done, let total):
            total == 1 ? "Sending your video\u{2026}"
                       : "Sending video \(min(done + 1, total)) of \(total)\u{2026}"
        case .attachingVideos:
            "Adding the videos\u{2026}"
        case .updatingProperties:
            "Finishing up\u{2026}"
        case .finishing:
            "Done"
        }
    }

    /// Which of the three things this stage is working on, so the UI can show a checklist
    /// rather than a single sentence that keeps being replaced.
    public enum Stage: Int, Sendable, CaseIterable {
        case words, photos, videos

        public var label: String {
            switch self {
            case .words: "Words"
            case .photos: "Photos"
            case .videos: "Videos"
            }
        }

        public var symbol: String {
            switch self {
            case .words: "text.alignleft"
            case .photos: "photo"
            case .videos: "video"
            }
        }
    }

    /// The stage currently being worked on. Nil while setting up or finishing, when nothing
    /// of the person's own is in flight.
    public var stage: Stage? {
        switch self {
        case .preparing, .creatingPage, .findingPage, .updatingProperties, .finishing:
            nil
        case .writingText:
            .words
        case .uploadingPhotos, .attachingPhotos:
            .photos
        case .uploadingVideos, .attachingVideos:
            .videos
        }
    }

    /// Whether a stage is already finished, so a checklist can tick it.
    ///
    /// Reads from the order of the work rather than from a stored list: every stage before
    /// the current one is done by definition, because they happen in sequence.
    public func hasFinished(_ stage: Stage) -> Bool {
        if case .finishing = self { return true }
        guard let current = self.stage else {
            // Before anything of theirs has been sent, nothing is done. Afterwards, all of it.
            return isAfterTheWork
        }
        return stage.rawValue < current.rawValue
    }

    private var isAfterTheWork: Bool {
        switch self {
        case .updatingProperties, .finishing: true
        default: false
        }
    }
}
