import Foundation

/// A bulk import, written down.
///
/// It used to live entirely in a sheet's `@State`: which photos had been read, which day
/// each belonged to, where each day was going, and how far the import had got. None of it was
/// anywhere else. So when the phone auto-locked partway through five hundred photos — which a
/// five hundred photo import all but guarantees — and iOS reclaimed the app in the
/// background, the whole thing was gone, and reopening the app landed on the entry list as if
/// nothing had been happening.
///
/// Now every photo is recorded here the moment it is safely on disk, every choice made in
/// review is recorded as it is made, and the plan is frozen before anything is attached. An
/// import that is interrupted at any point comes back exactly where it was.
public struct ImportSession: Codable, Sendable, Equatable, Identifiable {

    public enum Phase: String, Codable, Sendable {
        /// Photos are being read out of the picker.
        case staging
        /// Waiting on the person to confirm where things go.
        case reviewing
        /// Confirmed, and being attached to entries.
        case applying
    }

    public struct Item: Codable, Sendable, Equatable, Identifiable {
        /// Also the id the attached `MediaItem` will carry, which is what makes applying safe
        /// to repeat: an item whose id already exists in the journal was already attached.
        public let id: UUID
        /// Relative to the session's own directory.
        public let filename: String
        public let kind: MediaKind
        public let capturedAt: Date?
        /// Where it is going, fixed at the moment the person pressed Import. Nil until then.
        ///
        /// Frozen rather than recomputed on resume, because the default for a day depends on
        /// how many entries that day has — and a half-finished import may already have made
        /// one. Re-deriving the plan after an interruption could quietly send photos
        /// somewhere other than where the person was shown they would go.
        public var planned: ImportDestination?
        public var applied: Bool

        public init(
            id: UUID = UUID(),
            filename: String,
            kind: MediaKind,
            capturedAt: Date?,
            planned: ImportDestination? = nil,
            applied: Bool = false
        ) {
            self.id = id
            self.filename = filename
            self.kind = kind
            self.capturedAt = capturedAt
            self.planned = planned
            self.applied = applied
        }

        public var groupingItem: MediaDayGrouping.Item {
            MediaDayGrouping.Item(id: id, capturedAt: capturedAt)
        }
    }

    public let id: UUID
    public let startedAt: Date
    public var phase: Phase
    public var items: [Item]

    /// Per day, by `MediaDayGrouping.Group.id`. Absent means the default.
    public var groupDestinations: [String: ImportDestination]
    /// Per photo, overriding its day. Absent means "whatever the day is doing".
    public var itemDestinations: [UUID: ImportDestination]
    public var newEntryTitles: [String: String]

    /// Entries this import has already made, by group id.
    ///
    /// Recorded the moment each is created, before anything is attached to it. Without this a
    /// resumed import would make a second entry for the same Tuesday, because the only record
    /// of the first one was a local variable in a process that no longer exists.
    public var createdDrafts: [String: UUID]

    /// How many photos the picker handed over, so an import that was interrupted while still
    /// reading can say how many it did not get to.
    public var requested: Int

    public init(id: UUID = UUID(), startedAt: Date = Date(), requested: Int = 0) {
        self.id = id
        self.startedAt = startedAt
        self.phase = .staging
        self.items = []
        self.groupDestinations = [:]
        self.itemDestinations = [:]
        self.newEntryTitles = [:]
        self.createdDrafts = [:]
        self.requested = requested
    }

    // MARK: - Reading the plan

    public var groups: [MediaDayGrouping.Group] {
        MediaDayGrouping.group(items.map(\.groupingItem))
    }

    public func items(in group: MediaDayGrouping.Group) -> [Item] {
        let ids = Set(group.items.map(\.id))
        return items.filter { ids.contains($0.id) }
    }

    /// Where an item ends up: its own choice if it has one, then its day's, then the default.
    ///
    /// - Parameter existingDrafts: the entries already filed under that day. One is almost
    ///   certainly the one you meant; several is ambiguous, so the default is a new entry
    ///   rather than an arbitrary pick.
    public func destination(
        for item: Item,
        in group: MediaDayGrouping.Group,
        existingDrafts: [UUID]
    ) -> ImportDestination {
        if let own = itemDestinations[item.id] { return own }
        return groupDestination(for: group, existingDrafts: existingDrafts)
    }

    public func groupDestination(
        for group: MediaDayGrouping.Group, existingDrafts: [UUID]
    ) -> ImportDestination {
        if let chosen = groupDestinations[group.id] { return chosen }
        return existingDrafts.count == 1 ? .existingDraft(existingDrafts[0]) : .newDraft
    }

    /// Fixes every item's destination, ready to be applied.
    public mutating func freezePlan(existingDrafts: (CalendarDay?) -> [UUID]) {
        let groups = self.groups
        for group in groups {
            let existing = existingDrafts(group.day)
            for item in items(in: group) {
                guard let index = items.firstIndex(where: { $0.id == item.id }) else { continue }
                items[index].planned = destination(for: item, in: group, existingDrafts: existing)
            }
        }
        phase = .applying
    }

    /// The day an item belongs to, for items that need an entry made for them.
    public func groupId(of item: Item) -> String {
        groups.first { group in group.items.contains { $0.id == item.id } }?.id ?? "undated"
    }

    public func day(of groupId: String) -> CalendarDay? {
        groups.first { $0.id == groupId }?.day
    }

    public var remaining: [Item] {
        items.filter { !$0.applied && $0.planned != .skip }
    }

    public var isFinished: Bool { phase == .applying && remaining.isEmpty }

    /// Photos the picker handed over that were never read, because the app stopped before it
    /// got to them. They cannot be recovered after the fact — the picker's handles do not
    /// outlive the process — so the honest thing is to say how many.
    public var unread: Int { max(0, requested - items.count) }
}
