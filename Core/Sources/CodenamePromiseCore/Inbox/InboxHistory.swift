import Foundation

/// What the inbox has brought in lately, and from where, so a dump from the Mac or the share
/// sheet can be found again after the notice about it is gone.
///
/// The inbox files captures as soon as the app opens, often before anyone looks, and deletes
/// them from the folder once they're in the journal. Without this, "Check now" on a folder
/// already emptied had nothing to show for dumps that had in fact arrived.
///
/// Small and kept outside the journal on purpose, like `IngestLedger`: it's bookkeeping about
/// the inbox, and losing it loses no one's writing.
public final class InboxHistory: @unchecked Sendable {
    public struct Arrival: Codable, Sendable, Equatable, Identifiable {
        public enum Source: String, Codable, Sendable {
            case mac, shareSheet
        }

        public var id: UUID
        public let date: Date
        public let source: Source
        /// The entry it went into.
        public let entryId: UUID
        public let notes: Int
        /// Photos and videos.
        public let media: Int
        /// Which they were, so the app can say "2 photos" rather than "2 photos or videos".
        public let mediaIds: [UUID]
        public let recordings: Int

        public init(id: UUID = UUID(), date: Date, source: Source, entryId: UUID, notes: Int,
                    mediaIds: [UUID], recordings: Int) {
            self.id = id
            self.date = date
            self.source = source
            self.entryId = entryId
            self.notes = notes
            self.media = mediaIds.count
            self.mediaIds = mediaIds
            self.recordings = recordings
        }
    }

    private let defaults: UserDefaults
    private let key: String
    private let limit: Int
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = "inbox.history", limit: Int = 100) {
        self.defaults = defaults
        self.key = key
        self.limit = limit
    }

    /// Notes what a drain filed, one arrival per entry that gained something.
    public func record(_ filed: CaptureIngestor.Outcome, from source: Arrival.Source, at date: Date = Date()) {
        let arrivals = filed.added
            .map { entryId, added in
                Arrival(date: date, source: source, entryId: entryId,
                        notes: added.notes.count, mediaIds: added.mediaIds, recordings: added.recordings)
            }
            .filter { $0.notes + $0.media + $0.recordings > 0 }
        guard !arrivals.isEmpty else { return }
        lock.withLock {
            var all = stored
            all.append(contentsOf: arrivals)
            // Oldest out first.
            if all.count > limit { all.removeFirst(all.count - limit) }
            if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: key) }
        }
    }

    /// Newest first; with a source, only what came from there.
    public func arrivals(from source: Arrival.Source? = nil) -> [Arrival] {
        let all = lock.withLock { stored }
        return all
            .filter { source == nil || $0.source == source }
            .sorted { $0.date > $1.date }
    }

    private var stored: [Arrival] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Arrival].self, from: data)) ?? []
    }
}
