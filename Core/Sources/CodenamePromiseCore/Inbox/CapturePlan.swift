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
        /// Holds photos and videos that carry no date. Still filed under `day` (today) if
        /// left alone, but shown as "No date found" so they aren't mistaken for today's.
        /// Picking a day for it makes it an ordinary day.
        public var undated: Bool
        /// A title for the entry if it's new or untitled. Empty means none.
        public var title: String

        public init(id: UUID = UUID(), day: CalendarDay, text: String = "", entry: EntryChoice = .latest,
                    fileIds: [UUID] = [], undated: Bool = false, title: String = "") {
            self.id = id
            self.day = day
            self.text = text
            self.entry = entry
            self.fileIds = fileIds
            self.undated = undated
            self.title = title
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
    /// Nil means it carries no date, and it goes into the "No date found" group instead of
    /// quietly becoming today's.
    public mutating func place(_ fileId: UUID, on day: CalendarDay?, today: CalendarDay = .today()) {
        guard let day else {
            if let index = days.firstIndex(where: \.undated) {
                days[index].fileIds.append(fileId)
            } else if let index = days.firstIndex(where: { $0.isEmpty }) {
                days[index].day = today
                days[index].undated = true
                days[index].fileIds.append(fileId)
            } else {
                days.append(Day(day: today, fileIds: [fileId], undated: true))
            }
            sortDays()
            return
        }
        if let index = days.firstIndex(where: { $0.day == day && !$0.undated }) {
            days[index].fileIds.append(fileId)
        } else if let index = days.firstIndex(where: { $0.isEmpty }) {
            // The untouched starting day takes it rather than sitting empty above it.
            days[index].day = day
            days[index].undated = false
            days[index].fileIds.append(fileId)
        } else {
            days.append(Day(day: day, fileIds: [fileId]))
        }
        sortDays()
    }

    /// Moves one photo or video to another day, joining that day if it's already here.
    /// The day it left goes away if it's now empty, unless it's the only one.
    public mutating func move(_ fileId: UUID, to day: CalendarDay) {
        guard let from = days.firstIndex(where: { $0.fileIds.contains(fileId) }) else { return }
        if days[from].day == day && !days[from].undated { return }
        days[from].fileIds.removeAll { $0 == fileId }
        let leftId = days[from].id
        if let index = days.firstIndex(where: { $0.day == day && !$0.undated }) {
            days[index].fileIds.append(fileId)
        } else {
            days.append(Day(day: day, fileIds: [fileId]))
        }
        if let left = days.firstIndex(where: { $0.id == leftId }), days[left].isEmpty, days.count > 1 {
            days.remove(at: left)
        }
        sortDays()
    }

    /// Gives a day (usually the "No date found" group) a date. If that date is already
    /// here, the two become one rather than showing the same day twice.
    public mutating func setDay(_ day: CalendarDay, for id: UUID) {
        guard let index = days.firstIndex(where: { $0.id == id }) else { return }
        if let other = days.firstIndex(where: { $0.id != id && $0.day == day && !$0.undated }) {
            let moving = days[index]
            days[other].fileIds += moving.fileIds
            if moving.hasNote {
                days[other].text = days[other].hasNote ? days[other].text + "\n\n" + moving.text : moving.text
            }
            days.remove(at: index)
        } else {
            days[index].day = day
            days[index].undated = false
        }
        sortDays()
    }

    /// Undated first, so it's seen; then newest first.
    private mutating func sortDays() {
        days.sort { ($0.undated ? 1 : 0, $0.day) > ($1.undated ? 1 : 0, $1.day) }
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
                fileIds: day.fileIds,
                title: day.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : day.title.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
