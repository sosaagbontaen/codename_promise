import Foundation
import SwiftData

/// Filling the journal in from the Photos library: every photo and video filed under the day
/// it was taken, joining that day's entry or starting one.
///
/// The decisions that don't need the library itself live here, so they can be tested: which
/// items are already in the journal, and how the rest fall into days. The app does the
/// reading and copying (`PhotoBackfillCoordinator`).
public enum PhotoBackfill {
    /// One item in the library, as values.
    public struct Asset: Sendable, Hashable {
        /// The Photos library's identifier for it.
        public let id: String
        public let date: Date
        public let isVideo: Bool

        public init(id: String, date: Date, isVideo: Bool) {
            self.id = id
            self.date = date
            self.isVideo = isVideo
        }
    }

    public struct Day: Sendable, Equatable {
        public let day: CalendarDay
        public var assets: [Asset]
    }

    /// The attachment id a library item gets. Derived from the item, so running the fill
    /// again recognises everything it already brought in, however long ago, and adds only
    /// what's new.
    public static func mediaId(forAsset id: String) -> UUID {
        InboxScanner.stableUUID("photos|\(id)")
    }

    /// Photos taken in quick succession: runs of two or more with no more than `maxGap`
    /// between neighbours, in the order taken. Twenty frames of the same view while waiting
    /// for the right one shouldn't all land in the journal; these runs are where to look for
    /// them, and the app then checks which frames really look alike.
    public static func runs(_ assets: [Asset], maxGap: TimeInterval = 8) -> [[Asset]] {
        let photos = assets.filter { !$0.isVideo }.sorted { $0.date < $1.date }
        var runs: [[Asset]] = []
        var current: [Asset] = []
        for photo in photos {
            if let last = current.last, photo.date.timeIntervalSince(last.date) > maxGap {
                if current.count > 1 { runs.append(current) }
                current = []
            }
            current.append(photo)
        }
        if current.count > 1 { runs.append(current) }
        return runs
    }

    /// What's left to bring in, by day, oldest first, each day's items in the order taken.
    /// - Parameter leftOut: library ids someone chose not to bring in (the extra frames of a
    ///   run of similar shots), so a later fill doesn't offer them again.
    public static func plan(_ assets: [Asset], alreadyIn: Set<UUID>, leftOut: Set<String> = [],
                            timeZone: TimeZone = .current) -> [Day] {
        let wanted = assets.filter { !alreadyIn.contains(mediaId(forAsset: $0.id)) && !leftOut.contains($0.id) }
        let byDay = Dictionary(grouping: wanted) { CalendarDay(date: $0.date, timeZone: timeZone) }
        return byDay.keys.sorted().map { day in
            Day(day: day, assets: byDay[day, default: []].sorted { $0.date < $1.date })
        }
    }
}

extension DraftStore {
    /// Every attachment id in the journal, Recently Deleted included, so a fill doesn't
    /// bring back a photo someone has just thrown away with its entry.
    public func allMediaIds() throws -> Set<UUID> {
        Set(try context.fetch(FetchDescriptor<MediaItem>()).map(\.id))
    }
}
