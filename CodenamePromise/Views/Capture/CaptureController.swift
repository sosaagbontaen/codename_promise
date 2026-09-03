import CodenamePromiseCore
import Foundation
import Observation

/// Owns the editing buffer and the save discipline for one draft.
///
/// The shape here is the whole of ADR-001 in the UI layer:
///
///  - `TextEditor` binds to `text`, an in-memory buffer, so typing never writes to SwiftData
///    per keystroke (which would thrash the store without buying durability).
///  - Every change schedules a commit ~300ms later.
///  - Anything that could end the session — leaving the view, backgrounding, starting a
///    dictation — commits *immediately* rather than waiting for the debounce.
///
/// `saveState` is deliberately user-visible. The anxiety this app exists to remove is not
/// knowing whether your words are safe, so the answer is on screen.
@MainActor
@Observable
final class CaptureController {
    enum SaveState: Equatable {
        case saved
        case pending
        case failed(String)
    }

    var text: String {
        didSet {
            guard text != oldValue else { return }
            saveState = .pending
            scheduleCommit()
        }
    }

    var title: String {
        didSet {
            guard title != oldValue else { return }
            saveState = .pending
            scheduleCommit()
        }
    }

    private(set) var saveState: SaveState = .saved

    private let store: DraftStore
    private let draft: EntryDraft
    private var commitTask: Task<Void, Never>?

    /// Short enough that an unexpected kill costs at most a few words, long enough that
    /// ordinary typing doesn't commit on every character.
    private let debounce: Duration = .milliseconds(300)

    /// The model text this buffer was last in step with.
    ///
    /// Without it the editor cannot tell "the user typed" from "something else appended",
    /// and `commitNow` writes the buffer over whatever arrived. That is how a transcript
    /// could be merged successfully and then destroyed a fraction of a second later.
    private var modelBaseline: String

    init(draft: EntryDraft, store: DraftStore) {
        self.draft = draft
        self.store = store
        self.text = draft.content.rawText
        self.title = draft.content.title ?? ""
        self.modelBaseline = draft.content.rawText
        self.formatted = draft.content.formattedText ?? ""
    }

    /// Re-reads the structured text after the AI has rewritten it.
    func refreshFormattedFromStore() {
        formatted = draft.content.formattedText ?? ""
    }

    /// Folds in text that arrived from somewhere other than the keyboard — a transcript
    /// merged by the queue, typically — without discarding what the user has typed since.
    ///
    /// External writes are append-only, so when the model still starts with what the buffer
    /// was based on, the difference is purely the addition and can be appended to the
    /// buffer. If it doesn't (which shouldn't happen), the model wins: losing a few
    /// keystrokes is recoverable, losing a dictation is the thing this project exists to
    /// prevent.
    func absorbExternalChanges() {
        let current = draft.content.rawText
        guard current != modelBaseline else { return }

        text = TextMerge.absorbing(buffer: text, baseline: modelBaseline, current: current)
        modelBaseline = current
        saveState = .saved
    }

    var entryDate: CalendarDay { draft.entryDate }
    var draftId: UUID { draft.id }
    var mediaCount: Int { draft.media.count }
    var orderedMedia: [MediaItem] { draft.orderedMedia }
    var pendingTranscriptionCount: Int {
        draft.audioCaptures.filter { !$0.isSafeToDelete }.count
    }

    var needsSync: Bool { draft.needsSync(to: .notion) }

    /// Whether this entry already owns a page in the destination. Changes what syncing
    /// *means* — creating something new versus rewriting something that exists — so the
    /// label should change with it.
    var isLinkedToPage: Bool { notionSyncState?.externalId != nil }

    var hasFormatting: Bool { !(draft.content.formattedText ?? "").isEmpty }

    /// Whether the structured text has been hand-edited, so re-running formatting can ask
    /// before replacing it.
    var formattedTextWasEdited: Bool { draft.formattedTextEditedByUser }

    /// The structured text, editable. Same debounce-and-commit discipline as `text` — it's
    /// the user's writing once they've touched it, so it gets the same durability (ADR-001).
    var formatted: String {
        didSet {
            guard formatted != oldValue else { return }
            saveState = .pending
            scheduleCommit()
        }
    }

    var notionSyncState: SyncState? {
        draft.syncStates.first { $0.target == .notion }
    }

    /// What to tell the user about this entry's destination. `nil` means say nothing — a draft
    /// that has never been synced is not in a warning state, because sync is optional.
    var syncSummary: String? {
        guard let state = notionSyncState else { return nil }
        switch state.status {
        case .synced:
            return needsSync ? "Edited since last sync" : "Synced to Notion"
        case .failed:
            return state.lastSyncError ?? "Sync failed. Will retry."
        case .syncing:
            return "Syncing…"
        case .pending:
            return "Waiting to sync"
        }
    }

    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            commitNow()
        }
    }

    /// Commits immediately. Call before anything that could interrupt the session.
    func commitNow() {
        commitTask?.cancel()
        commitTask = nil

        // Anything that landed while the user was typing gets folded in first, so the write
        // below extends it rather than replacing it.
        absorbExternalChanges()

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if draft.content.rawText != text {
                try store.updateRawText(text, for: draft)
                modelBaseline = text
            }
            let newTitle = trimmedTitle.isEmpty ? nil : trimmedTitle
            if draft.content.title != newTitle {
                try store.updateTitle(newTitle, for: draft)
            }
            // Only when there is formatting to edit — an empty buffer on an unformatted
            // entry must not create one.
            if hasFormatting, draft.content.formattedText != formatted {
                try store.updateFormattedText(formatted, for: draft)
            }
            saveState = .saved
        } catch {
            // Surfaced, never swallowed: silently believing work is safe is the failure mode
            // this whole design exists to prevent.
            saveState = .failed(error.localizedDescription)
        }
    }

    /// Points this entry at one that already exists in Notion, to add to rather than replace.
    func attachToExistingPage(_ pageId: String, title: String?) {
        draft.syncState(for: .notion).attachToExistingPage(pageId, title: title)
        do {
            try store.flush()
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    var appendsToExistingPage: Bool { notionSyncState?.appendsToExistingPage ?? false }

    /// What to call the action, in terms of the entry it will actually touch. "Update my
    /// addition" told the user nothing about *which* entry — the name is the whole point.
    var syncActionLabel: String {
        guard appendsToExistingPage else {
            return isLinkedToPage ? "Update existing page" : "Send to Notion"
        }
        guard let title = notionSyncState?.externalTitle, !title.isEmpty else {
            return "Add to that entry"
        }
        let trimmed = title.count > 24 ? String(title.prefix(24)) + "…" : title
        return "Add to \"\(trimmed)\""
    }

    /// Where this entry lives in the destination, if it's been pushed. Nil until it has.
    var destinationLink: (app: URL?, web: URL)? {
        guard let state = notionSyncState else { return nil }
        return DestinationLink.url(for: state)
    }

    /// Surfaces a failure that happened before anything was written — picking an item that
    /// wouldn't load. Nothing was lost, but the user has to be told it didn't happen.
    func reportAttachmentFailure(_ message: String) {
        saveState = .failed(message)
    }

    /// Detaches this entry from the Notion page it currently points at, so the next sync
    /// creates a page of its own. Nothing is deleted from Notion.
    func unlinkFromNotion() {
        draft.syncState(for: .notion).unlinkFromDestination()
        do {
            try store.flush()
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    func setEntryDate(_ day: CalendarDay) {
        do {
            try store.setEntryDate(day, for: draft)
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Dictation

    /// Persists a finished recording and returns the capture, or nil on failure.
    ///
    /// Ordering matters: the in-progress text is committed first, then the audio is written
    /// and committed. Transcription is a separate, failable step that happens afterwards —
    /// losing it costs convenience, never words. See ADR-002.
    @discardableResult
    func attachRecording(data: Data, durationSeconds: Double, fileStore: MediaFileStore) -> AudioCapture? {
        commitNow()
        do {
            let capture = try store.attachAudioCapture(
                data: data,
                fileExtension: "m4a",
                durationSeconds: durationSeconds,
                to: draft,
                fileStore: fileStore
            )
            saveState = .saved
            // The recording is on disk before transcription is even attempted (ADR-002).
            // That is the moment worth confirming, not the transcript arriving later.
            Haptics.landed()
            return capture
        } catch {
            saveState = .failed(error.localizedDescription)
            Haptics.failed()
            return nil
        }
    }

    // MARK: - Media

    /// PhotosUI hands over `Data`, not a stable URL. It goes to a temp file purely so
    /// `MediaFileStore.adopt` can copy it into the container — the temp file is never
    /// referenced by a model. See ADR-007.
    func attachPhoto(data: Data, fileExtension: String, kind: MediaKind, fileStore: MediaFileStore) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("incoming-\(UUID().uuidString).\(fileExtension)")
        do {
            try data.write(to: temp, options: .atomic)
            defer { try? FileManager.default.removeItem(at: temp) }
            attachPhoto(from: temp, kind: kind, fileStore: fileStore)
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    func attachPhoto(from url: URL, kind: MediaKind, fileStore: MediaFileStore) {
        commitNow()
        do {
            let item = try store.attachMedia(from: url, kind: kind, to: draft, fileStore: fileStore)
            saveState = .saved

            // The original is on disk and committed before this runs (ADR-007). Compression
            // produces a derivative for upload and never touches what the user attached.
            //
            // Chained rather than fired off independently: attaching five clips at once would
            // otherwise start five video encoders together, which is slower overall and, on a
            // phone, hot and battery-hungry.
            let previous = compressionChain
            compressionChain = Task { [fileStore, store] in
                await previous?.value
                await MediaCompressor(fileStore: fileStore, store: store).compressIfNeeded(item)
            }
            trackCompression()
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    /// True while a derivative is being produced. Syncing before it finishes would upload the
    /// full-size original, which Notion rejects for anything over its size limit.
    private(set) var isCompressingMedia = false

    /// Serialises compression across attachments. Each new item waits for the previous.
    private var compressionChain: Task<Void, Never>?

    /// Counts queued compressions so the indicator clears only when the last one finishes.
    /// `Task` is a value type, so identity comparison isn't available — a generation number is.
    private var compressionGeneration = 0

    private func trackCompression() {
        isCompressingMedia = true
        compressionGeneration += 1
        let generation = compressionGeneration
        let chain = compressionChain
        Task {
            await chain?.value
            // Only clear if nothing else was queued behind this one.
            if compressionGeneration == generation { isCompressingMedia = false }
        }
    }

    /// Waits for any in-flight compression. Sync calls this so it uploads the derivative
    /// rather than racing it and sending the full-size original.
    func waitForMediaCompression() async {
        await compressionChain?.value
    }

    /// Moves selected attachments onto another entry.
    ///
    /// Nothing is copied and nothing is deleted — see `DraftStore.moveMedia`. Returns how
    /// many actually moved so the caller can say so.
    @discardableResult
    func moveMedia(ids: Set<UUID>, to destination: EntryDraft) -> Int {
        commitNow()
        do {
            let moved = try store.moveMedia(ids: ids, from: draft, to: destination)
            saveState = .saved
            if moved > 0 { Haptics.committed() }
            return moved
        } catch {
            saveState = .failed(error.localizedDescription)
            return 0
        }
    }

    func removeMedia(id: UUID, fileStore: MediaFileStore) {
        do {
            try store.removeMedia(id: id, from: draft, fileStore: fileStore)
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }
}
