import Foundation

/// Sorting a pile of photos into the days they were taken.
///
/// The workflow this serves: at the end of a few days you dump everything from the camera
/// roll into the app at once, and it works out which day each shot belongs to rather than you
/// having to remember. Remembering is exactly the thing that goes wrong — and the system photo
/// picker gives no help with it.
///
/// The date comes from the file's own metadata, which matters: it means this needs no photo
/// library permission at all. The picker already hands over the file; the file already knows
/// when it was taken.
public enum MediaDayGrouping {

    /// One item to be sorted. `capturedAt` is nil when the file carries no usable date —
    /// screenshots and some edited images have had their EXIF stripped.
    public struct Item: Sendable, Hashable, Identifiable {
        public let id: UUID
        public let capturedAt: Date?

        public init(id: UUID, capturedAt: Date?) {
            self.id = id
            self.capturedAt = capturedAt
        }
    }

    /// Items that were taken on one day, or the undated ones.
    public struct Group: Sendable, Hashable, Identifiable {
        /// Nil for items with no readable capture date.
        public let day: CalendarDay?
        public let items: [Item]

        public var id: String { day?.rawValue ?? "undated" }
        public var isUndated: Bool { day == nil }

        public init(day: CalendarDay?, items: [Item]) {
            self.day = day
            self.items = items
        }
    }

    /// Groups items by the calendar day they were captured, newest day first.
    ///
    /// Undated items are kept as their own group rather than being guessed at or dropped. A
    /// photo filed under the wrong day is worse than one the user is asked about, and one
    /// silently discarded is worst of all.
    public static func group(
        _ items: [Item],
        timeZone: TimeZone = .current
    ) -> [Group] {
        var byDay: [CalendarDay: [Item]] = [:]
        var undated: [Item] = []

        for item in items {
            guard let capturedAt = item.capturedAt else {
                undated.append(item)
                continue
            }
            // The user's timezone, not UTC: a photo taken at 11pm belongs to that evening,
            // which is the same reasoning as ADR-006.
            byDay[CalendarDay(date: capturedAt, timeZone: timeZone), default: []].append(item)
        }

        var groups = byDay
            .sorted { $0.key > $1.key }
            .map { Group(day: $0.key, items: $0.value) }

        if !undated.isEmpty {
            // Last, because it needs a decision rather than a glance.
            groups.append(Group(day: nil, items: undated))
        }
        return groups
    }
}

/// What the user chose to do with one day's worth of photos.
public enum ImportDestination: Sendable, Hashable {
    /// Add to a draft that already exists for that day.
    case existingDraft(UUID)
    /// Start a new draft, dated to the day the photos were taken.
    case newDraft
    /// Leave these out.
    case skip
}
