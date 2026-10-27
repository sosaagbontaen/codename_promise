import Foundation

/// What a capture is going to do, arranged by day, while someone is still putting it together.
///
/// Journaling is about days, so a capture is too. Each day carries its own note, its own
/// photos and videos, and its own choice of entry. Photos sort themselves into the day they
/// were taken as they are added, the way the bulk import does, and a note can be written for
/// any day, with or without photos beside it.
///
/// Shared by the Mac panel and the share sheet, so the two can't drift apart.
public struct CapturePlan: Sendable, Equatable {

    public enum EntryChoice: Hashable, Sendable {
        /// That day's most recently edited entry, or a new one if it has none.
        case latest
        case new
        case existing(UUID)

        /// What a menu should show as chosen. "Latest" is never offered as its own option:
        /// it's the same as picking that day's newest entry, which the menu already lists,
        /// so it shows as that entry, or as "New entry" when the day has none.
        ///
        /// - Parameter entries: the day's entries, newest first.
        public func shown(among entries: [EntryIndex.Entry]) -> EntryChoice {
            guard self == .latest else { return self }
            return entries.first.map { .existing($0.id) } ?? .new
        }
    }

    public struct Day: Identifiable, Sendable, Equatable {
        public let id: UUID
        public var day: CalendarDay
        public var text: String
        public var entry: EntryChoice
        public var fileIds: [UUID]

        public init(id: UUID = UUID(), day: CalendarDay, text: String = "", entry: EntryChoice = .latest, fileIds: [UUID] = []) {
            self.id = id
            self.day = day
            self.text = text
            self.entry = entry
            self.fileIds = fileIds
        }

        public var hasNote: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        public var isEmpty: Bool { !hasNote && fileIds.isEmpty }
    }

    public private(set) var days: [Day]

    /// Starts with one empty day, today, ready to type into.
    public init(today: CalendarDay = .today()) {
        days = [Day(day: today)]
    }

    public var isEmpty: Bool { days.allSatisfy(\.isEmpty) }

    public var fileCount: Int { days.reduce(0) { $0 + $1.fileIds.count } }

    public subscript(id: UUID) -> Day? {
        get { days.first { $0.id == id } }
        set {
            guard let index = days.firstIndex(where: { $0.id == id }) else { return }
            if let newValue { days[index] = newValue } else { days.remove(at: index) }
        }
    }

    /// Files a photo under the day it was taken, joining that day if it's already here.
    public mutating func place(_ fileId: UUID, on day: CalendarDay) {
        if let index = days.firstIndex(where: { $0.day == day }) {
            days[index].fileIds.append(fileId)
        } else if let index = days.firstIndex(where: { $0.isEmpty }) {
            // The untouched starting day takes it rather than sitting empty above it.
            days[index].day = day
            days[index].fileIds.append(fileId)
        } else {
            days.append(Day(day: day, fileIds: [fileId]))
        }
        days.sort { $0.day > $1.day }
    }

    public mutating func remove(file fileId: UUID) {
        for index in days.indices { days[index].fileIds.removeAll { $0 == fileId } }
        dropEmptyDays()
    }

    /// Adds a day to write a note for. Returns its id so the caller can focus it.
    @discardableResult
    public mutating func addDay(_ day: CalendarDay) -> UUID {
        let added = Day(day: day)
        days.append(added)
        return added.id
    }

    public mutating func removeDay(_ id: UUID) {
        days.removeAll { $0.id == id }
        if days.isEmpty { days = [Day(day: .today())] }
    }

    /// Clears out days with nothing in them, keeping at least one to type into.
    public mutating func dropEmptyDays() {
        let kept = days.filter { !$0.isEmpty }
        days = kept.isEmpty ? [days.first.map { Day(id: $0.id, day: $0.day) } ?? Day(day: .today())] : kept
    }

    /// The manifest groups this plan becomes. Empty days are left out.
    public var groups: [Capture.Group] {
        days.filter { !$0.isEmpty }.map { day in
            var entryId: UUID?
            var newEntry = false
            switch day.entry {
            case .latest: break
            case .new: newEntry = true
            case .existing(let id): entryId = id
            }
            return Capture.Group(
                id: day.id, day: day.day, entryId: entryId, newEntry: newEntry,
                text: day.hasNote ? day.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                fileIds: day.fileIds
            )
        }
    }
}
