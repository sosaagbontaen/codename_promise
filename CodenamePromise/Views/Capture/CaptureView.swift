import AVFoundation
import CodenamePromiseCore
import PhotosUI
import SwiftUI

/// The capture surface. Typing, dictation and media, in that order of importance.
///
/// Two things here are load-bearing rather than decorative:
///
///  - The editor binds to a buffer, not to the model. Commits are debounced, and forced on
///    anything that could end the session (ADR-001).
///  - Save state is on screen. The anxiety this app exists to remove is not knowing whether
///    your words are safe.
struct CaptureView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    @State private var controller: CaptureController
    @State private var recorder = AudioRecorder()
    @State private var photoSelections: [PhotosPickerItem] = []
    @State private var attachProgress: (done: Int, total: Int)?
    @State private var viewingMedia: ViewingMedia?
    @State private var confirmingReformat = false
    @State private var showingDatePicker = false
    @State private var showingEntryPicker = false
    @State private var mode: Mode = .raw
    @State private var selectedMedia = Set<UUID>()
    @State private var selectingMedia = false
    @State private var showingMoveSheet = false
    @State private var moveNotice: String?

    /// Which version of the entry is on screen. `rawText` is always editable; the AI's
    /// structured pass is read-only, because it is a view of the user's words rather than a
    /// second place to write them.
    enum Mode: String, CaseIterable { case raw = "Yours", formatted = "Structured" }

    private let fileStore: MediaFileStore
    /// Kept so the move sheet can list the other entries. The controller deliberately owns
    /// one draft, and picking a destination is a question about all of them.
    private let store: DraftStore

    init(draft: EntryDraft, store: DraftStore, fileStore: MediaFileStore) {
        _controller = State(initialValue: CaptureController(draft: draft, store: store))
        self.fileStore = fileStore
        self.store = store
    }

    var body: some View {
        // safeAreaInset rather than a VStack: a VStack just parks the panel on top of the
        // scroll view, so the last of the content - the media selection bar, "Open in
        // Notion" - sat underneath it, visible but untappable. An inset tells the scroll
        // view the panel is there, so content scrolls clear of it.
        editor
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    syncProgressBar
                    actionPanel
                }
            }
        .navigationTitle(dayLabel)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { hideKeyboard() }
                    .font(Type.label(15, .semibold))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingDatePicker = true
                } label: {
                    Label("Change day", systemImage: "calendar")
                }
            }

        }
        .confirmationDialog(
            "Replace your edits?",
            isPresented: $confirmingReformat,
            titleVisibility: .visible
        ) {
            Button("Format again", role: .destructive) {
                Task { await runFormatting() }
            }
        } message: {
            Text("You've edited the structured text by hand. Formatting again will replace it. Your own words in \"Yours\" are untouched either way.")
        }
        .sheet(isPresented: $showingMoveSheet) {
            MoveMediaSheet(
                count: selectedMedia.count,
                store: store,
                fileStore: fileStore,
                excluding: controller.draftId
            ) { destination in
                performMove(to: destination)
            }
        }
        .sheet(item: $viewingMedia) { viewing in
            MediaViewer(
                items: controller.orderedMedia,
                fileStore: fileStore,
                selection: viewing.id
            )
            // Medium detent plus background interaction is the whole point: the photo is
            // large enough to jog a memory while the editor stays live behind it, so you can
            // keep writing without dismissing anything.
            .presentationDetents([.medium, .large])
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingEntryPicker) {
            if let service = services.connectionService {
                ExistingEntryPicker(service: service) { page in
                    controller.attachToExistingPage(page.id, title: page.title)
                }
            }
        }
        .sheet(isPresented: $showingDatePicker) {
            EntryDayPicker(current: controller.entryDate) { day in
                controller.setEntryDate(day)
            }
        }
        // Leaving the view is exactly the moment a debounce must not be trusted.
        .onDisappear { controller.commitNow() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                controller.commitNow()
            } else {
                // A drain may have merged a transcript while the app was away.
                controller.absorbExternalChanges()
            }
        }
        .onChange(of: photoSelections) { _, items in
            guard !items.isEmpty else { return }
            Task { await adopt(items) }
        }
    }

    /// Whether there is anything to say about this entry beyond its own words.
    private var hasFooterNotes: Bool {
        controller.pendingTranscriptionCount > 0
            || attachProgress != nil
            || controller.appendsToExistingPage
            || !statusMessages.isEmpty
            || controller.destinationLink != nil
    }

    // MARK: - Editor

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // A page for a day. The nav bar already carries the date, but small and in
                // chrome; saying it here gives the entry somewhere to be rather than making
                // it a text box that happens to be open.
                Text(controller.entryDate.representativeDate()
                    .formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(Type.caption(11.5, .bold))
                    .foregroundStyle(Brand.azure)
                    .textCase(.uppercase)
                    .tracking(1.1)
                    .padding(.top, 6)

                TextField("Title (optional)", text: $controller.title)
                    .font(Type.title(25))
                    .textInputAutocapitalization(.sentences)

                if controller.hasFormatting {
                    Picker("View", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.bottom, 2)
                    .onChange(of: mode) { Haptics.picked() }
                }

                Group {
                    if mode == .formatted, controller.hasFormatting {
                        TextEditor(text: $controller.formatted)
                            .writingSurface()
                    } else {
                        TextEditor(text: $controller.text)
                            .writingSurface()
                            .overlay(alignment: .topLeading) {
                                if controller.text.isEmpty {
                                    Text("What went well today?")
                                        .font(Type.journal(17))
                                        .foregroundStyle(.tertiary)
                                        .padding(.top, 8)
                                        .padding(.leading, 5)
                                        .allowsHitTesting(false)
                                }
                            }
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: mode)

                if !controller.orderedMedia.isEmpty {
                    mediaStrip
                }


                // Everything below is *about* the entry rather than part of it, so it sits
                // together on its own ground instead of trailing off as loose grey text.
                if hasFooterNotes {
                    VStack(alignment: .leading, spacing: 10) {
                        if controller.pendingTranscriptionCount > 0 {
                            queuedRecordingsNotice
                        }

                        if let attachProgress {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.mini)
                                Text("Adding \(attachProgress.done) of \(attachProgress.total)\u{2026}")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if controller.appendsToExistingPage {
                            Label(
                                controller.notionSyncState?.externalTitle.map {
                                    "Will be added to the end of \"\($0)\""
                                } ?? "Will be added to the end of an existing Notion entry",
                                systemImage: "text.append"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        ForEach(statusMessages, id: \.self) { message in
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        // Right after a sync this is where you're already looking, so put
                        // the way to go and see the result here rather than only in a menu.
                        if controller.destinationLink != nil {
                            Button {
                                openInDestination()
                            } label: {
                                Label("Open in Notion", systemImage: "arrow.up.forward.app")
                                    .font(.caption.weight(.medium))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Brand.azure)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        // Otherwise this screen falls back to the system ground, which is pure black in dark
        // mode and does not match anything else in the app.
        .background(Brand.ground)
    }

    private var mediaStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(controller.orderedMedia, id: \.id) { item in
                        MediaThumbnail(
                            item: item,
                            fileStore: fileStore,
                            selecting: selectingMedia,
                            isSelected: selectedMedia.contains(item.id)
                        ) {
                            controller.removeMedia(id: item.id, fileStore: fileStore)
                        } onOpen: {
                            if selectingMedia {
                                toggleSelection(item.id)
                            } else {
                                viewingMedia = ViewingMedia(id: item.id)
                            }
                        }
                    }
                }
            }
            .frame(height: 88)

            mediaSelectionBar
        }
    }

    /// Selection lives under the strip rather than in the toolbar: the toolbar belongs to the
    /// entry, and this acts on the photos.
    @ViewBuilder
    private var mediaSelectionBar: some View {
        if selectingMedia {
            HStack(spacing: 14) {
                Button("Done") { endSelection() }

                Button(selectedMedia.count == controller.orderedMedia.count ? "None" : "All") {
                    if selectedMedia.count == controller.orderedMedia.count {
                        selectedMedia.removeAll()
                    } else {
                        selectedMedia = Set(controller.orderedMedia.map(\.id))
                    }
                }

                Spacer()

                Button {
                    showingMoveSheet = true
                } label: {
                    Label("Move \(selectedMedia.count)", systemImage: "arrow.right.doc.on.clipboard")
                }
                .disabled(selectedMedia.isEmpty)
            }
            .font(.footnote)
        } else {
            HStack(spacing: 14) {
                Button {
                    selectingMedia = true
                } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }
                if let moveNotice {
                    Text(moveNotice)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                Spacer()
            }
            .font(.footnote)
        }
    }

    private func toggleSelection(_ id: UUID) {
        if selectedMedia.contains(id) {
            selectedMedia.remove(id)
        } else {
            selectedMedia.insert(id)
        }
    }

    /// Confirms in place. The photos vanish from this entry, so saying nothing would look
    /// exactly like having deleted them.
    private func performMove(to destination: EntryDraft) {
        let moved = controller.moveMedia(ids: selectedMedia, to: destination)
        endSelection()
        guard moved > 0 else { return }
        let name = destinationName(destination)
        withAnimation { moveNotice = "Moved \(moved) to \(name)" }
        Task {
            try? await Task.sleep(for: .seconds(4))
            withAnimation { moveNotice = nil }
        }
    }

    private func destinationName(_ draft: EntryDraft) -> String {
        if let title = draft.content.title, !title.isEmpty { return title }
        return draft.entryDate.representativeDate().formatted(.dateTime.month().day())
    }

    private func endSelection() {
        selectingMedia = false
        selectedMedia.removeAll()
    }

    /// Honest about the current state of the world: the recording is safe, and transcription
    /// simply hasn't happened. Queued, not lost. See ADR-019a.
    private var queuedRecordingsNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.badge.exclamationmark")
            Text("\(controller.pendingTranscriptionCount) recording\(controller.pendingTranscriptionCount == 1 ? "" : "s") saved, waiting to transcribe")
                .font(.footnote)
            if services.transcriptions?.isRunning == true {
                ProgressView().controlSize(.mini)
            }
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - The action panel

    /// Everything you can do to this entry, pinned and visible without scrolling.
    ///
    /// This has now been wrong in both directions. It started as a second bottom bar stacked
    /// on the tab bar - two rows of chrome. Moving it inline fixed that and broke something
    /// worse: on an entry with any text at all, attaching media, choosing a destination and
    /// sending were all below the fold, which is the same as not existing.
    ///
    /// One panel, pinned. Status and destination on a single line, actions and the primary
    /// on the next. Two lines rather than two bars, and nothing important is ever a scroll
    /// away.
    private var actionPanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                saveStateLabel
                Spacer(minLength: 8)
                destinationButton
            }

            HStack(spacing: 10) {
                PhotosPicker(
                    selection: $photoSelections, maxSelectionCount: nil,
                    matching: .any(of: [.images, .videos])
                ) {
                    CompactAction(symbol: "photo.on.rectangle.angled", tint: Brand.Mode.photo)
                }
                .disabled(recorder.isRecording)

                Button {
                    Haptics.committed()
                    Task { await recorder.start() }
                } label: {
                    CompactAction(symbol: "mic.fill", tint: Brand.Mode.voice)
                }
                .buttonStyle(.pressable)
                .disabled(recorder.isRecording)

                Button {
                    formatOrConfirm()
                } label: {
                    CompactAction(symbol: "sparkles", tint: Brand.ai)
                }
                .buttonStyle(.pressable)
                .disabled(controller.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                sendButton
            }
            .overlay { if recorder.isRecording { recordingCapsule } }
            .animation(.easeOut(duration: 0.18), value: recorder.isRecording)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private var recordingCapsule: some View {
        Button {
            Haptics.committed()
            stopRecording()
        } label: {
            HStack(spacing: 12) {
                LiveWaveform(levels: recorder.levels, tint: .white)
                    .frame(height: 20).frame(maxWidth: .infinity)
                Text(elapsedLabel).font(Type.mono(13)).foregroundStyle(.white)
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Brand.gradient, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Where this entry goes, on the same line as its save state so both are read at once.
    private var destinationButton: some View {
        Button {
            showingEntryPicker = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: controller.appendsToExistingPage ? "text.append" : "doc.badge.plus")
                    .font(.system(size: 11, weight: .semibold))
                Text(destinationTitle).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
            }
            .font(Type.caption(12, .semibold))
            .foregroundStyle(Brand.violet)
        }
        .buttonStyle(.pressable)
        .disabled(services.connectionService == nil)
    }

    private var destinationTitle: String {
        if services.connectionService == nil { return "Not connected" }
        if controller.appendsToExistingPage { return controller.syncActionLabel }
        return controller.isLinkedToPage ? "Its Notion page" : "New Notion page"
    }

    /// One obvious primary action, where a small arrow in the toolbar used to open a menu.
    private var sendButton: some View {
        Button {
            Task { await pushToNotion() }
        } label: {
            Group {
                if services.sync?.isSyncing(controller.draftId) == true {
                    ProgressView().tint(.white)
                } else {
                    Label(sendTitle, systemImage: canSend ? "arrow.up" : "checkmark")
                        .font(Type.label(14.5, .semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(canSend ? .white : Brand.muted)
            .frame(maxWidth: .infinity).frame(height: 46)
            .background(
                canSend ? AnyShapeStyle(Brand.gradient)
                        : AnyShapeStyle(Brand.muted.opacity(0.16)),
                in: RoundedRectangle(cornerRadius: 13)
            )
            .shadow(color: Brand.violet.opacity(canSend ? 0.3 : 0), radius: 12, y: 5)
        }
        .buttonStyle(.pressablePrimary)
        .disabled(!canSend)
        .animation(.easeOut(duration: 0.18), value: canSend)
    }

    private var canSend: Bool {
        controller.needsSync
            && !controller.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && services.sync?.isSyncing(controller.draftId) != true
    }

    private var sendTitle: String {
        if !controller.needsSync && controller.isLinkedToPage { return "Up to date" }
        if controller.appendsToExistingPage { return "Add to page" }
        return controller.isLinkedToPage ? "Update page" : "Send to Notion"
    }

    // MARK: - Footer



    @ViewBuilder
    /// The one always-visible answer to "are my words safe".
    ///
    /// It used to be a bare green tick in the toolbar, which is not an answer - a checkmark
    /// alone could mean saved, synced, or done, and it meant only the first. It carries its
    /// word now, and it reports the queue too: a recording that has not been transcribed yet
    /// is the state people most need reassuring about, and it was previously described only
    /// below the fold.
    private var saveStateLabel: some View {
        Group {
            switch controller.saveState {
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Brand.failed)
                    .lineLimit(1)
            case .pending:
                Label("Saving\u{2026}", systemImage: "ellipsis.circle")
                    .foregroundStyle(Brand.muted)
            case .saved where controller.pendingTranscriptionCount > 0:
                // Saved, but with words still waiting to become text. Say both.
                Label(
                    "Saved \u{00B7} \(controller.pendingTranscriptionCount) to transcribe",
                    systemImage: "waveform"
                )
                .foregroundStyle(Brand.waiting)
                .lineLimit(1)
            case .saved:
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Brand.reached)
            }
        }
        .font(Type.caption(12, .semibold))
        .transition(.opacity)
        .animation(.easeOut(duration: 0.2), value: controller.pendingTranscriptionCount)
    }



    /// Transcription and sync fail for the same reasons and phrase them the same way, so
    /// showing both verbatim prints the identical sentence twice. Deduplicated, order kept.
    private var statusMessages: [String] {
        var seen = Set<String>()
        var messages: [String] = []
        let candidates = [
            controller.pendingTranscriptionCount > 0 ? services.transcriptions?.blockedReason : nil,
            services.formatting?.blockedReason,
            controller.syncSummary,
        ]
        for case let message? in candidates where seen.insert(message).inserted {
            messages.append(message)
        }
        return messages
    }

    /// Real progress, not a spinner: the fraction comes from phases the sync has actually
    /// completed, so a stall shows a stalled bar rather than reassuring motion.
    @ViewBuilder
    private var syncProgressBar: some View {
        if let step = services.sync?.progress(for: controller.draftId) {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: step.fraction)
                Text(step.message).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }


    private var elapsedLabel: String {
        let total = Int(recorder.elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var dayLabel: String {
        controller.entryDate.representativeDate()
            .formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    // MARK: - Actions

    private func stopRecording() {
        guard let result = recorder.stop() else { return }
        guard controller.attachRecording(
            data: result.data,
            durationSeconds: result.duration,
            fileStore: fileStore
        ) != nil else { return }
        // The audio is committed at this point. Transcription is a separate, failable step —
        // if this never succeeds, the recording is still safe and still queued. See ADR-002.
        Task {
            await services.drainTranscriptions()
            // The queue writes straight to the model, so the editor has to be told. Without
            // this the transcript is invisible and the next keystroke overwrites it.
            controller.absorbExternalChanges()
        }
    }

    /// Asks first when there are hand-edits to lose. Formatting replaces the structured
    /// text wholesale, and silently discarding someone's edits is the failure this whole
    /// project is organised against.
    private func formatOrConfirm() {
        if controller.formattedTextWasEdited {
            confirmingReformat = true
        } else {
            Task { await runFormatting() }
        }
    }

    private func runFormatting() async {
        // Commit first: formatting must be derived from what the user has actually written,
        // not from whatever the last debounce happened to catch.
        controller.commitNow()
        if await services.formatting?.format(draftId: controller.draftId) == .formatted {
            // The coordinator wrote straight to the model, so the editor buffer has to catch
            // up — the same lesson as the transcript that got overwritten by a stale buffer.
            controller.refreshFormattedFromStore()
            mode = .formatted
        }
    }

    private func pushToNotion() async {
        // Flush the buffer first, or the sync snapshots content the user has already moved on
        // from — the debounce may not have fired yet. See ADR-001 / ADR-016.
        controller.commitNow()
        // And wait for compression, or this uploads the full-size original and gets it
        // rejected for being over the destination's size limit.
        await controller.waitForMediaCompression()
        await services.sync?.sync(draftId: controller.draftId)
    }

    /// Forgets whichever page this entry points at and syncs to a fresh one.
    ///
    /// The escape hatch for an entry bound to the wrong page — and the way to keep several
    /// entries on one day as separate pages rather than having them share one.
    /// Prefers Notion's own app and falls back to the web.
    ///
    /// The custom scheme opens the app directly but does nothing when it isn't installed, so
    /// it's only used after checking. The https URL always resolves, and on a device with the
    /// app a universal link usually hands off to it anyway.
    private func openInDestination() {
        guard let link = controller.destinationLink else { return }
        if let appURL = link.app, UIApplication.shared.canOpenURL(appURL) {
            openURL(appURL)
        } else {
            openURL(link.web)
        }
    }

    private func pushAsNewPage() async {
        controller.commitNow()
        controller.unlinkFromNotion()
        await services.sync?.sync(draftId: controller.draftId)
    }

    /// Brings picked photos and videos into the app's own storage, one at a time.
    ///
    /// Sequential on purpose. Each attachment queues a transcode, and running several at once
    /// would have half a dozen video encoders competing for the CPU — slower overall, and on a
    /// phone, hot and battery-hungry. It also keeps `sortIndex` in the order the user picked.
    ///
    /// One item failing doesn't stop the rest: the same principle as media not failing an
    /// entry (ADR-015a). Failures are collected and reported together at the end.
    private func adopt(_ items: [PhotosPickerItem]) async {
        defer {
            photoSelections = []
            attachProgress = nil
        }

        var failures: [String] = []
        for (index, item) in items.enumerated() {
            attachProgress = (done: index, total: items.count)
            if let failure = await adoptOne(item) {
                failures.append(failure)
            }
        }

        if failures.count == items.count, let first = failures.first {
            // Everything failed — the specific reason is more useful than a count.
            controller.reportAttachmentFailure(first)
        } else if !failures.isEmpty {
            controller.reportAttachmentFailure(
                "\(failures.count) of \(items.count) items couldn't be added. The rest were."
            )
        }
    }

    /// Returns a description of what went wrong, or nil on success.
    ///
    /// Videos need a file representation, not `Data` — `loadTransferable(type: Data.self)`
    /// returns nil for most movies, and iCloud-backed items can fail while they download.
    /// Both used to be swallowed by a `try?`, so picking a video did nothing and said nothing.
    private func adoptOne(_ item: PhotosPickerItem) async -> String? {
        let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }

        do {
            if isVideo {
                guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                    return "Couldn't load that video. If it's stored in iCloud, open it in Photos first."
                }
                defer { try? FileManager.default.removeItem(at: movie.url) }
                controller.attachPhoto(from: movie.url, kind: .video, fileStore: fileStore)
            } else {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    return "Couldn't load that photo. If it's stored in iCloud, open it in Photos first."
                }
                controller.attachPhoto(
                    data: data, fileExtension: "jpg", kind: .photo, fileStore: fileStore
                )
            }
            return nil
        } catch {
            return "Couldn't load that item: \(error.localizedDescription)"
        }
    }
}

// MARK: - Supporting views

/// One of the three round actions, sharing the Dump screen's language.
///
/// A view rather than a method on `CaptureView`: `PhotosPicker`'s label closure is
/// nonisolated and cannot call a main-actor member.
/// A compact action for the pinned panel: icon only, because the panel has to carry three
/// of them plus the primary on one line.
struct CompactAction: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 46, height: 46)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 13))
    }
}

struct ActionCircle: View {
    let title: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 52, height: 52)
                .background(tint.opacity(0.13), in: Circle())
            Text(title).font(Type.caption(11.5, .medium)).foregroundStyle(Brand.muted)
        }
        .frame(maxWidth: .infinity)
    }
}

struct MediaThumbnail: View {
    let item: MediaItem
    let fileStore: MediaFileStore
    var selecting: Bool = false
    var isSelected: Bool = false
    let onRemove: () -> Void
    var onOpen: () -> Void = {}

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onOpen) {
                thumbnail
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        if selecting && isSelected {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.accentColor, lineWidth: 3)
                        }
                    }
                    .opacity(selecting && !isSelected ? 0.55 : 1)
            }
            .buttonStyle(.plain)

            // While selecting, the corner control is the tick — offering delete in the same
            // spot would put "remove for good" one slip away from "choose".
            if selecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .white, .black.opacity(0.6))
                    .padding(2)
            } else {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .padding(2)
            }
        }
    }

    @State private var image: UIImage?

    @ViewBuilder
    private var thumbnail: some View {
        if let image {
            ZStack {
                Image(uiImage: image).resizable().scaledToFill()
                if item.kind == .video {
                    // So a still frame reads as a video at a glance.
                    Image(systemName: "play.circle.fill")
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                }
            }
        } else {
            ZStack {
                Color.secondary.opacity(0.2)
                Image(systemName: item.kind == .video ? "video.fill" : "photo")
                    .foregroundStyle(.secondary)
            }
            .task {
                image = await ThumbnailCache.shared.thumbnail(for: item, fileStore: fileStore)
            }
        }
    }
}

/// Wrapper so a bare `UUID` can drive `.sheet(item:)`. Conforming `UUID` itself would be a
/// retroactive conformance on a stdlib type — cheap now, a source of conflicts later.
struct ViewingMedia: Identifiable {
    let id: UUID
}

/// Lets the user file an entry under the day it is *about*, which is the whole point of
/// `entryDate` existing separately from `createdAt`. See ADR-006.
struct EntryDayPicker: View {
    let current: CalendarDay
    let onPick: (CalendarDay) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Date

    init(current: CalendarDay, onPick: @escaping (CalendarDay) -> Void) {
        self.current = current
        self.onPick = onPick
        _selection = State(initialValue: current.representativeDate())
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                DatePicker("Entry day", selection: $selection, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                Text("Which day is this entry about? Journaling after midnight about yesterday is the common case, not the exception.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .navigationTitle("Entry day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onPick(CalendarDay(date: selection))
                        dismiss()
                    }
                }
            }
        }
    }
}
