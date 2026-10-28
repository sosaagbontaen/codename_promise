import AVFoundation
import Foundation

/// Files a capture into the journal.
///
/// Where things go, in order of precedence:
///
/// A capture arranged by day (`Capture.groups`) is filed one day at a time, each to the entry
/// chosen for it. Older captures and loose files are routed like this:
///
/// 1. An entry the person picked, if it still exists.
/// 2. A day they picked: a new entry if they asked for one, otherwise that day's most recently
///    edited entry, otherwise a new entry for that day.
/// 3. Neither: text and recordings by the day they were jotted.
///
/// Separately, photos and videos can be placed by the day each was taken (the bulk-import
/// rule) while the note still goes where it was aimed. A photo with no date in it goes with
/// the note.
///
/// Running the same capture twice files nothing twice. Attachments keep the id the capture
/// gave them, text is skipped if the entry already says it, and any entry created here gets
/// an id derived from the capture, so a retry after a crash finds the entry it made last time
/// rather than starting another one.
@MainActor
public final class CaptureIngestor {

    public struct Outcome: Sendable, Equatable {
        public var captures = 0
        public var photos = 0
        public var videos = 0
        public var recordings = 0
        public var jots = 0
        /// Entries that gained something, so the app can point at them.
        public var entryIds: Set<UUID> = []
        /// What went into each entry, for the digest the app shows afterwards.
        public var added: [UUID: Added] = [:]

        public init() {}

        /// What one entry gained.
        public struct Added: Sendable, Equatable {
            /// Each note exactly as it was appended, in order.
            public var notes: [String] = []
            /// Photos and videos, in the order they were attached.
            public var mediaIds: [UUID] = []
            public var recordings = 0

            public init() {}
        }

        public var isEmpty: Bool { photos + videos + recordings + jots == 0 }

        public static func += (lhs: inout Outcome, rhs: Outcome) {
            lhs.captures += rhs.captures
            lhs.photos += rhs.photos
            lhs.videos += rhs.videos
            lhs.recordings += rhs.recordings
            lhs.jots += rhs.jots
            lhs.entryIds.formUnion(rhs.entryIds)
            for (id, added) in rhs.added {
                var merged = lhs.added[id] ?? Added()
                merged.notes += added.notes
                merged.mediaIds += added.mediaIds
                merged.recordings += added.recordings
                lhs.added[id] = merged
            }
        }
    }

    private let store: DraftStore
    private let fileStore: MediaFileStore
    private let timeZone: TimeZone

    public init(store: DraftStore, fileStore: MediaFileStore, timeZone: TimeZone = .current) {
        self.store = store
        self.fileStore = fileStore
        self.timeZone = timeZone
    }

    /// Files everything in `ready`. Throws, having filed some of it, if a file can't be read;
    /// the capture should then be left in the inbox and tried again, which is safe.
    public func ingest(_ ready: InboxScanner.Ready) async throws -> Outcome {
        let capture = ready.capture
        var outcome = Outcome()
        outcome.captures = 1

        if let groups = capture.groups {
            // Arranged by day: each day's note and files go to that day's entry, in that order,
            // so a note reads as the caption for the photos under it.
            let filesById = Dictionary(capture.files.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for group in groups {
                let chosen = try group.entryId.flatMap { try store.draft(id: $0) }
                let draft = try chosen ?? self.entry(
                    for: capture, day: group.day, newEntry: group.newEntry,
                    key: group.newEntry ? "group|\(group.id.uuidString)" : group.day.rawValue
                )
                if let title = group.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                   (draft.content.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    draft.updateTitle(title)
                    try store.flush()
                    outcome.entryIds.insert(draft.id)
                }
                if let text = group.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    if try append(text, to: draft) {
                        outcome.jots += 1
                        outcome.added[draft.id, default: Outcome.Added()].notes.append(text)
                    }
                    outcome.entryIds.insert(draft.id)
                }
                for fileId in group.fileIds {
                    guard let file = filesById[fileId] else { continue }
                    try await attach(file, from: ready.directory, to: draft, outcome: &outcome)
                }
            }
            return outcome
        }

        let chosen: EntryDraft? = try capture.destination.entryId.flatMap { try store.draft(id: $0) }
        let jottedOn = CalendarDay(date: capture.createdAt, timeZone: timeZone)
        func entryOn(_ day: CalendarDay) throws -> EntryDraft {
            try self.entry(for: capture, day: day, newEntry: capture.destination.newEntry, key: day.rawValue)
        }

        // Text first: a jot written alongside photos reads as their caption, so it goes
        // where it was written, before what it describes.
        if let text = capture.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let draft = try chosen ?? entryOn(capture.destination.day ?? jottedOn)
            if try append(text, to: draft) {
                        outcome.jots += 1
                        outcome.added[draft.id, default: Outcome.Added()].notes.append(text)
                    }
            outcome.entryIds.insert(draft.id)
        }

        for file in capture.files {
            let draft: EntryDraft
            if (file.kind == .photo || file.kind == .video), capture.destination.filesByCaptureDate {
                // A photo with no date in it (most screenshots) goes with the note.
                let fallback = capture.destination.day ?? jottedOn
                let url = ready.directory.appendingPathComponent(file.name)
                let day = await takenOn(url, kind: file.kind == .video ? .video : .photo) ?? fallback
                if let chosen, chosen.entryDate == day {
                    draft = chosen
                } else {
                    draft = try entryOn(day)
                }
            } else {
                draft = try chosen ?? entryOn(capture.destination.day ?? jottedOn)
            }
            try await attach(file, from: ready.directory, to: draft, outcome: &outcome)
        }
        return outcome
    }

    /// Puts one file into `draft`, unless it is already in the journal.
    private func attach(
        _ file: Capture.File, from directory: URL, to draft: EntryDraft, outcome: inout Outcome
    ) async throws {
        let url = directory.appendingPathComponent(file.name)
        switch file.kind {
        case .photo, .video:
            if try store.mediaItem(id: file.id) != nil { return }
            let kind: MediaKind = file.kind == .video ? .video : .photo
            try store.attachMedia(from: url, kind: kind, to: draft, fileStore: fileStore, id: file.id)
            if kind == .video { outcome.videos += 1 } else { outcome.photos += 1 }
            outcome.added[draft.id, default: Outcome.Added()].mediaIds.append(file.id)

        case .audio:
            if try store.audioCapture(id: file.id) != nil { return }
            let duration = await Self.duration(of: url)
            let adopted = try fileStore.adopt(fileAt: url, id: file.id, preferredName: "dictation")
            try store.attachAudioCapture(
                id: adopted.id,
                relativePath: adopted.relativePath,
                sizeBytes: adopted.sizeBytes,
                durationSeconds: duration,
                to: draft
            )
            outcome.recordings += 1
            outcome.added[draft.id, default: Outcome.Added()].recordings += 1

        case .text:
            let text = try String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if try append(text, to: draft) {
                        outcome.jots += 1
                        outcome.added[draft.id, default: Outcome.Added()].notes.append(text)
                    }
        }
        outcome.entryIds.insert(draft.id)
    }

    // MARK: - Routing

    /// The entry a capture's things go to on `day`.
    ///
    /// - Parameter key: what makes an entry this capture creates its own. Derived, so a retry
    ///   after a crash finds what the interrupted run already made.
    private func entry(for capture: Capture, day: CalendarDay, newEntry: Bool, key: String) throws -> EntryDraft {
        let madeHere = InboxScanner.stableUUID("\(capture.id.uuidString)|\(key)")
        if let existing = try store.draft(id: madeHere) { return existing }

        if !newEntry,
           let latest = try store.drafts(on: day).max(by: { $0.updatedAt < $1.updatedAt }) {
            return latest
        }
        return try store.createDraft(id: madeHere, entryDate: day, timeZone: timeZone)
    }

    /// Appends unless the entry already contains it. Returns whether anything changed.
    private func append(_ text: String, to draft: EntryDraft) throws -> Bool {
        if draft.content.rawText.contains(text) { return false }
        draft.appendRawText(text)
        try store.flush()
        return true
    }

    private func takenOn(_ url: URL, kind: MediaKind) async -> CalendarDay? {
        let date: Date?
        switch kind {
        case .photo: date = CaptureDateReader.captureDate(ofImageAt: url)
        case .video: date = await CaptureDateReader.captureDate(ofVideoAt: url)
        }
        return date.map { CalendarDay(date: $0, timeZone: timeZone) }
    }

    private static func duration(of url: URL) async -> Double {
        guard let time = try? await AVURLAsset(url: url).load(.duration), time.isNumeric else { return 0 }
        return max(0, time.seconds)
    }
}
