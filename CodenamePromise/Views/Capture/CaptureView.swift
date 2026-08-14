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

    /// Which version of the entry is on screen. `rawText` is always editable; the AI's
    /// structured pass is read-only, because it is a view of the user's words rather than a
    /// second place to write them.
    enum Mode: String, CaseIterable { case raw = "Yours", formatted = "Structured" }

    private let fileStore: MediaFileStore

    init(draft: EntryDraft, store: DraftStore, fileStore: MediaFileStore) {
        _controller = State(initialValue: CaptureController(draft: draft, store: store))
        self.fileStore = fileStore
    }

    var body: some View {
        VStack(spacing: 0) {
            editor
            syncProgressBar
            Divider()
            footer
        }
        .navigationTitle(dayLabel)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingDatePicker = true
                } label: {
                    Label("Change day", systemImage: "calendar")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                syncButton
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

    // MARK: - Editor

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Title (optional)", text: $controller.title)
                    .font(.title3.weight(.semibold))
                    .textInputAutocapitalization(.sentences)

                if controller.hasFormatting {
                    Picker("View", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                if mode == .formatted, controller.hasFormatting {
                    TextEditor(text: $controller.formatted)
                        .font(.body)
                        .frame(minHeight: 320)
                } else {
                    TextEditor(text: $controller.text)
                        .font(.body)
                        .frame(minHeight: 320)
                        .overlay(alignment: .topLeading) {
                            if controller.text.isEmpty {
                                Text("What went well today?")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                }

                if !controller.orderedMedia.isEmpty {
                    mediaStrip
                }

                if controller.pendingTranscriptionCount > 0 {
                    queuedRecordingsNotice
                }

                if let attachProgress {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text("Adding \(attachProgress.done) of \(attachProgress.total)…")
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

                // Right after a sync this is where you're already looking, so put the way to
                // go and see the result here rather than only in a menu.
                if controller.destinationLink != nil {
                    Button {
                        openInDestination()
                    } label: {
                        Label("Open in Notion", systemImage: "arrow.up.forward.app")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }

    private var mediaStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(controller.orderedMedia, id: \.id) { item in
                    MediaThumbnail(item: item, fileStore: fileStore) {
                        controller.removeMedia(id: item.id, fileStore: fileStore)
                    } onOpen: {
                        viewingMedia = ViewingMedia(id: item.id)
                    }
                }
            }
        }
        .frame(height: 88)
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

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 16) {
            saveStateLabel

            Spacer()

            // `maxSelectionCount: nil` means unlimited — reopening the picker for every
            // single photo is needless friction when someone is writing up a whole day.
            PhotosPicker(
                selection: $photoSelections,
                maxSelectionCount: nil,
                matching: .any(of: [.images, .videos])
            ) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.title3)
            }

            formatButton
            dictationButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    @ViewBuilder
    private var saveStateLabel: some View {
        switch controller.saveState {
        case .saved:
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
        case .pending:
            Label("Saving…", systemImage: "ellipsis.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .lineLimit(1)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var dictationButton: some View {
        switch recorder.state {
        case .recording:
            Button {
                stopRecording()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "stop.circle.fill")
                    Text(elapsedLabel).monospacedDigit()
                }
                .font(.title3)
                .foregroundStyle(.red)
            }
        case .denied:
            // Actionable rather than merely informative — the fix lives in iOS Settings.
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Mic off", systemImage: "mic.slash")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        case .failed(let message):
            // Previously fell into `default`, which drew the mic button again — so a failure
            // looked exactly like a button that does nothing.
            Button {
                Task { await recorder.start() }
            } label: {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(.orange)
            }
        case .idle:
            Button {
                Task { await recorder.start() }
            } label: {
                Image(systemName: "mic.circle.fill").font(.title3)
            }
        }
    }

    @ViewBuilder
    private var formatButton: some View {
        if services.formatting?.isFormatting(controller.draftId) == true {
            ProgressView().controlSize(.small)
        } else {
            Button {
                formatOrConfirm()
            } label: {
                Image(systemName: "sparkles").font(.title3)
            }
            .disabled(controller.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
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

    @ViewBuilder
    private var syncButton: some View {
        if services.sync?.isSyncing(controller.draftId) == true {
            ProgressView().controlSize(.small)
        } else {
            // The menu depends on where this entry currently lives, because otherwise the
            // options are either duplicates or quietly destructive. A brand-new entry was
            // offered both "Send to Notion" and "Send as a new page" — the same action twice
            // — while an entry that already owned a page was offered "Add to an existing
            // entry", which would have re-pointed it and orphaned the page it had created.
            Menu {
                if controller.isLinkedToPage {
                    if controller.destinationLink != nil {
                        Button {
                            openInDestination()
                        } label: {
                            Label("Open in Notion", systemImage: "arrow.up.forward.app")
                        }

                        Divider()
                    }

                    Button {
                        Task { await pushToNotion() }
                    } label: {
                        Label(
                            controller.syncActionLabel,
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .disabled(!controller.needsSync || controller.text.isEmpty)

                    if controller.appendsToExistingPage {
                        Button {
                            showingEntryPicker = true
                        } label: {
                            Label("Choose a different entry…", systemImage: "text.append")
                        }
                    }

                    Divider()

                    Button {
                        Task { await pushAsNewPage() }
                    } label: {
                        Label("Send as a new page instead", systemImage: "doc.badge.plus")
                    }
                    .disabled(controller.text.isEmpty)
                } else {
                    Button {
                        Task { await pushToNotion() }
                    } label: {
                        Label("Send to Notion", systemImage: "arrow.up.circle")
                    }
                    .disabled(!controller.needsSync || controller.text.isEmpty)

                    Button {
                        showingEntryPicker = true
                    } label: {
                        Label("Add to an existing entry…", systemImage: "text.append")
                    }
                    .disabled(services.connectionService == nil)
                }
            } label: {
                Label("Sync", systemImage: controller.needsSync ? "arrow.up.circle" : "checkmark.icloud")
            }
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

struct MediaThumbnail: View {
    let item: MediaItem
    let fileStore: MediaFileStore
    let onRemove: () -> Void
    var onOpen: () -> Void = {}

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onOpen) {
                thumbnail
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .padding(2)
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
