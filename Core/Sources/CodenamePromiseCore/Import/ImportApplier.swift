import Foundation

/// Attaches a confirmed import to the journal, and can be stopped at any point and run again.
///
/// The old version attached five hundred photos in one uninterrupted loop on the main thread:
/// a file copy and a database save each, with nothing yielding in between. The screen froze
/// behind a spinner that could not animate, which reads exactly like a hang, and anything
/// that stopped it partway — the phone locking, the app being reclaimed — left an unknown
/// number of photos attached and no record of which.
///
/// This one does the same work in a way that survives being stopped:
///
/// - **Every item carries its own id into the journal.** Before attaching anything it asks
///   whether an attachment with that id already exists, so running the import twice attaches
///   each photo once. That is the whole safety argument for resuming, and it holds whether the
///   last run stopped before a save, after it, or between the two.
/// - **An entry this import made is written down before anything is put in it**, so a resume
///   adds to the Tuesday it already started instead of starting a second one.
/// - **It yields after every photo**, so the progress bar moves and the app stays usable while
///   it works.
@MainActor
public struct ImportApplier {
    public struct Outcome: Sendable, Equatable {
        public var attached = 0
        public var entriesMade = 0
        /// Photos whose staged file was gone and which were not already in the journal.
        public var missing = 0
    }

    private let store: DraftStore
    private let fileStore: MediaFileStore
    private let sessions: ImportSessionStore

    /// How often the plan is written back while applying. Every photo would also be safe,
    /// but the id check already makes a lost checkpoint harmless, and five hundred rewrites of
    /// a growing file is work for nothing.
    private let checkpointEvery: Int

    public init(
        store: DraftStore,
        fileStore: MediaFileStore,
        sessions: ImportSessionStore,
        checkpointEvery: Int = 20
    ) {
        self.store = store
        self.fileStore = fileStore
        self.sessions = sessions
        self.checkpointEvery = checkpointEvery
    }

    public func apply(
        _ session: inout ImportSession,
        progress: (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) async throws -> Outcome {
        precondition(session.phase == .applying, "freeze the plan before applying it")

        var outcome = Outcome()
        let work = session.remaining
        let total = work.count
        var sinceCheckpoint = 0
        progress(0, total)

        for (index, item) in work.enumerated() {
            defer { progress(index + 1, total) }
            guard let position = session.items.firstIndex(where: { $0.id == item.id }) else {
                continue
            }

            // Already in the journal: the last run got this far and stopped before it could
            // say so. Record it and move on.
            if try store.mediaItem(id: item.id) != nil {
                session.items[position].applied = true
                removeStaged(item, in: session)
                continue
            }

            let source = sessions.url(for: item, in: session)
            guard FileManager.default.fileExists(atPath: source.path) else {
                // Not staged and not attached. Counted rather than silently skipped, so the
                // summary can say so.
                session.items[position].applied = true
                outcome.missing += 1
                continue
            }

            guard let draft = try draft(for: item, in: &session, outcome: &outcome) else {
                continue
            }

            _ = try store.attachMedia(
                from: source, kind: item.kind, to: draft, fileStore: fileStore, id: item.id
            )
            session.items[position].applied = true
            outcome.attached += 1
            removeStaged(item, in: session)

            sinceCheckpoint += 1
            if sinceCheckpoint >= checkpointEvery {
                try sessions.save(session)
                sinceCheckpoint = 0
            }

            // The difference between a frozen screen and a progress bar.
            await Task.yield()
        }

        try sessions.save(session)
        return outcome
    }

    /// The entry an item goes into, making it if this import has not made it yet.
    private func draft(
        for item: ImportSession.Item,
        in session: inout ImportSession,
        outcome: inout Outcome
    ) throws -> EntryDraft? {
        switch item.planned ?? .skip {
        case .skip:
            return nil

        case .existingDraft(let id):
            if let draft = try store.draft(id: id) { return draft }
            // Deleted between review and now. The photo still has to go somewhere, and a new
            // entry for its own day is the least surprising place — far better than dropping
            // it because the entry it was aimed at went away.
            return try newDraft(for: item, in: &session, outcome: &outcome)

        case .newDraft:
            return try newDraft(for: item, in: &session, outcome: &outcome)
        }
    }

    private func newDraft(
        for item: ImportSession.Item,
        in session: inout ImportSession,
        outcome: inout Outcome
    ) throws -> EntryDraft {
        let groupId = session.groupId(of: item)
        if let existing = session.createdDrafts[groupId], let draft = try store.draft(id: existing) {
            return draft
        }

        // An undated group has no day to file under, so it becomes today's entry; the date
        // picker moves it.
        let draft = try store.createDraft(entryDate: session.day(of: groupId) ?? .today())
        let title = (session.newEntryTitles[groupId] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { try store.updateTitle(title, for: draft) }

        // Written down *now*, before anything is attached to it. See `createdDrafts`.
        session.createdDrafts[groupId] = draft.id
        try sessions.save(session)
        outcome.entriesMade += 1
        return draft
    }

    private func removeStaged(_ item: ImportSession.Item, in session: ImportSession) {
        try? FileManager.default.removeItem(at: sessions.url(for: item, in: session))
    }
}
