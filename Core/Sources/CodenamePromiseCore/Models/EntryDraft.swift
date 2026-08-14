import Foundation
import SwiftData

/// The aggregate root. Never replaced, only enriched.
///
/// Notes on the SwiftData shape, all of which are deliberate:
///
/// - No `@Attribute(.unique)` on `id`. Client-generated UUIDs are already unique, so the
///   constraint bought nothing while making the store incompatible with CloudKit — which
///   would have quietly foreclosed multi-device sync. See ADR-008b.
/// - Every stored property has a default, so future schema additions stay lightweight
///   migrations instead of heavyweight ones.
/// - Relationships are optional on the child side and declare explicit inverses, so
///   "which draft owns this file" is answerable and delete rules actually fire.
@Model
public final class EntryDraft {
    public private(set) var id: UUID = UUID()

    /// Immutable after creation (invariant 1).
    public private(set) var createdAt: Date = Date()

    /// Bumped by every *content* mutation (invariant 2, as amended by ADR-016:
    /// sync bookkeeping is explicitly excluded).
    public private(set) var updatedAt: Date = Date()

    /// The day this entry is about. See `CalendarDay` and ADR-006.
    public private(set) var entryDateKey: String = CalendarDay.today().rawValue

    public var content: EntryContent = EntryContent()

    @Relationship(deleteRule: .cascade, inverse: \MediaItem.draft)
    public var media: [MediaItem] = []

    @Relationship(deleteRule: .cascade, inverse: \AudioCapture.draft)
    public var audioCaptures: [AudioCapture] = []

    @Relationship(deleteRule: .cascade, inverse: \SyncState.draft)
    public var syncStates: [SyncState] = []

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        entryDate: CalendarDay? = nil,
        timeZone: TimeZone = .current
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = createdAt
        // Default the day from the creation instant *in the user's timezone*, but keep it
        // user-editable — a 00:30 entry about yesterday is the common case, not the edge.
        self.entryDateKey = (entryDate ?? CalendarDay(date: createdAt, timeZone: timeZone)).rawValue
        self.content = EntryContent()
    }

    // MARK: - Derived

    public var entryDate: CalendarDay {
        // Falls back to the creation day rather than trapping: an unparseable key must
        // never make an entry unreadable.
        CalendarDay(rawValue: entryDateKey) ?? CalendarDay(date: createdAt)
    }

    public var contentHash: String { content.contentHash }

    /// Media in a stable, user-meaningful order. SwiftData to-many relationships are
    /// set-backed, so array order is incidental and can change between launches — always
    /// read through this. See ADR-011.
    public var orderedMedia: [MediaItem] {
        media.sorted { ($0.sortIndex, $0.id.uuidString) < ($1.sortIndex, $1.id.uuidString) }
    }

    public var orderedAudioCaptures: [AudioCapture] {
        audioCaptures.sorted { ($0.chunkIndex, $0.id.uuidString) < ($1.chunkIndex, $1.id.uuidString) }
    }

    // MARK: - Content mutations

    /// The user's own words. Formatting must never call this.
    public func updateRawText(_ text: String, now: Date = Date()) {
        content.rawText = text
        touch(now)
    }

    /// Appends transcribed speech. Dictation appends rather than replaces, so a second
    /// recording in the same session can't wipe the first.
    public func appendRawText(_ text: String, now: Date = Date()) {
        guard !text.isEmpty else { return }
        if content.rawText.isEmpty {
            content.rawText = text
        } else {
            content.rawText += content.rawText.hasSuffix("\n") ? text : "\n\n" + text
        }
        touch(now)
    }

    public func updateTitle(_ title: String?, now: Date = Date()) {
        content.title = title
        touch(now)
    }

    /// Writes the AI's structural pass. `rawText` is untouched by construction — there is
    /// no code path from here to it (invariant 3).
    public func applyFormatting(_ formatted: String, formatterVersion: String, now: Date = Date()) {
        content.formattedText = formatted
        content.formatterVersion = formatterVersion
        // A fresh pass replaces whatever was there, hand-edits included — callers are
        // expected to have asked first. See `formattedTextEditedByUser`.
        content.formattedTextEditedByUser = false
        touch(now)
    }

    /// The user editing the AI's structured output by hand.
    ///
    /// Distinct from `applyFormatting`, which is the AI writing. `rawText` is untouched by
    /// either — invariant 3 is about what the *formatter* may do, and a person editing their
    /// own entry is not that.
    public func updateFormattedText(_ text: String, now: Date = Date()) {
        content.formattedText = text
        content.formattedTextEditedByUser = true
        touch(now)
    }

    public func setEntryDate(_ day: CalendarDay, now: Date = Date()) {
        entryDateKey = day.rawValue
        touch(now)
    }

    // MARK: - Attachments

    public func attach(_ item: MediaItem, now: Date = Date()) {
        item.sortIndex = (media.map(\.sortIndex).max() ?? -1) + 1
        media.append(item)
        touch(now)
    }

    public func attach(_ capture: AudioCapture, now: Date = Date()) {
        capture.chunkIndex = (audioCaptures.map(\.chunkIndex).max() ?? -1) + 1
        audioCaptures.append(capture)
        touch(now)
    }

    /// Detaches the record only. The bytes on disk are the caller's responsibility via
    /// `MediaFileStore` — a cascade delete rule removes rows, never files. See ADR-018a.
    public func detachMedia(id: UUID, now: Date = Date()) -> MediaItem? {
        guard let index = media.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = media.remove(at: index)
        removed.draft = nil
        touch(now)
        return removed
    }

    // MARK: - Sync bookkeeping

    /// The sync record for a destination, created on first use.
    ///
    /// This is where invariant 6 ("at most one SyncState per target") is actually
    /// enforced. SwiftData cannot express a uniqueness constraint scoped to a parent, so
    /// nothing but this accessor should ever append to `syncStates`.
    public func syncState(for target: SyncTarget) -> SyncState {
        if let existing = syncStates.first(where: { $0.target == target }) {
            return existing
        }
        let created = SyncState(target: target)
        // Append only — the declared inverse sets `created.draft` for us. Setting both
        // sides can double-register the child.
        syncStates.append(created)
        // Deliberately no touch(): creating a sync record is not a content change.
        return created
    }

    /// Whether this destination is behind the current content.
    public func needsSync(to target: SyncTarget) -> Bool {
        guard let state = syncStates.first(where: { $0.target == target }) else { return true }
        guard state.status == .synced else { return true }
        return state.syncedContentHash != contentHash
    }

    // MARK: - Private

    private func touch(_ now: Date) {
        updatedAt = now
    }
}
