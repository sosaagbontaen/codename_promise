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
    /// For the zoom from the cover into the full-screen viewer.
    @Namespace private var coverZoom
    /// How far the cover is being pulled down past the top.
    @State private var coverPull: CGFloat = 0
    @State private var showingDatePicker = false
    @State private var showingEntryPicker = false
    @State private var showingSendSheet = false
    @State private var mode: Mode = .raw
    @State private var selectedMedia = Set<UUID>()
    @State private var selectingMedia = false
    @State private var showingMoveSheet = false
    @State private var showingAttachments = false
    @State private var moveNotice: String?
    /// Which field has the keyboard, so the pinned details can get out of its way.
    @FocusState private var writing: Bool
    @FocusState private var titling: Bool

    /// Whether the pinned bars are folded away, leaving the entry on its own.
    ///
    /// Stored rather than per-screen: somebody who wants the page out of the way wants it out
    /// of the way for every entry, not one at a time. It is a toggle in the toolbar, so a
    /// person who forgets they set it is one tap from the answer.
    @AppStorage("entryChromeHidden") private var chromeHidden = false

    /// Which version of the entry is on screen. `rawText` is always editable; the AI's
    /// structured pass is read-only, because it is a view of the user's words rather than a
    /// second place to write them.
    /// `formatted` has no way to be produced any more: the action that made it was retired
    /// once arranging did the same job better, and having two AI buttons whose difference
    /// nobody could name was the confusion rather than the feature.
    ///
    /// The case stays because the text does. Entries written before the change still carry
    /// `formattedText`, and it is still exported, so nothing anybody wrote has been thrown
    /// away. It is simply not offered: a tab you cannot produce and have no reason to read
    /// is the confusion this removal was for, and keeping it visible for old entries meant
    /// the app still shipped two AI views with a difference nobody could name.
    ///
    /// Deleting the field itself would be a schema change that destroyed existing entries to
    /// tidy an enum, which is not a trade worth making.
    enum Mode: String, CaseIterable {
        case raw = "Raw", organised = "Formatted"
    }

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
                    // Hidden on request and while typing, but never mid-recording: the stop
                    // button lives here. While typing it rode up on the keyboard with a gap
                    // under it, which is why Done moved to the top bar instead.
                    if (!chromeHidden && !isEditingText) || recorder.isActive {
                        actionPanel
                    }
                }
                .animation(.easeInOut(duration: 0.22), value: chromeHidden)
            }
        // One date, not two.
        //
        // The nav bar said "Tue, Sep 1" and an eyebrow said "TUESDAY, SEPTEMBER 1" directly
        // underneath it - the same fact twice, four millimetres apart, which is the sort of
        // thing that reads as an unfinished screen even when nobody can say why.
        //
        // The eyebrow won, because it is the one in the app's own voice rather than in system
        // chrome, and it is now pinned above the scroll view instead of living inside it. That
        // was the nav title's only real advantage: it survived scrolling. Now both do, and
        // there is only one of them.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // No tab bar while writing.
        //
        // Two floating controls were landing in the strip below the action panel and getting
        // clipped by it: the minimized tab bar on the left, the keyboard's "Done" on the
        // right. Both anchor to the bottom of the screen, which is where the panel already
        // is. Insetting cannot fix that - neither one is scroll content.
        //
        // Hiding it is the right answer regardless of the collision. This is a drill-down
        // editing surface reached by pushing from a list, and switching tabs from inside one
        // is not something anyone does mid-sentence. Going back brings it straight back.
        .toolbar(.hidden, for: .tabBar)
        // One menu rather than a row of glyphs. Everything in it is occasional, and a labelled
        // list is easier to find things in than icons you have to learn.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isEditingText {
                    // Where Notes puts it: up here, not on a bar over the keyboard.
                    Button("Done") { hideKeyboard() }
                        .fontWeight(.semibold)
                        .tint(Brand.violet)
                } else {
                Menu {
                    Button {
                        showingDatePicker = true
                    } label: {
                        Label("Change day", systemImage: "calendar")
                    }
                    if !controller.orderedMedia.isEmpty {
                        Button {
                            showingAttachments = true
                        } label: {
                            Label("All photos and videos", systemImage: "square.grid.2x2")
                        }
                        Button {
                            selectingMedia = true
                        } label: {
                            Label("Select photos", systemImage: "checkmark.circle")
                        }
                        Button {
                            selectingMedia = true
                            selectedMedia = Set(controller.coverIds)
                        } label: {
                            Label("Choose cover photos", systemImage: "photo.stack")
                        }
                        if !controller.coverIds.isEmpty {
                            Button {
                                controller.setCovers([])
                            } label: {
                                Label("Clear cover photos", systemImage: "photo.badge.minus")
                            }
                        }
                    }
                    Divider()
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) { chromeHidden.toggle() }
                        Haptics.picked()
                    } label: {
                        Label(
                            chromeHidden ? "Show the toolbar" : "Hide the toolbar",
                            systemImage: chromeHidden ? "rectangle.bottomhalf.inset.filled" : "rectangle"
                        )
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .tint(Brand.ink)
                }
            }
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
        // Full screen, the way Photos opens a picture: tap one, it fills the screen, swipe
        // through the rest, pull down to close. The half-height sheet it replaced read as a
        // drawer of thumbnails rather than a look at the photo.
        .fullScreenCover(item: $viewingMedia) { viewing in
            MediaViewer(
                items: controller.orderedMedia,
                fileStore: fileStore,
                selection: viewing.id
            )
            // Zooms out of the photo that was tapped, the way Photos does, rather than
            // sliding a new screen up from the bottom.
            .modifier(ZoomFrom(id: viewing.id, namespace: coverZoom))
        }
        .sheet(isPresented: $showingSendSheet) { sendSheet }
        .sheet(isPresented: $showingAttachments) {
            AttachmentsView(
                items: controller.orderedMedia,
                fileStore: fileStore,
                onReorder: { controller.reorderMedia($0) },
                onRemove: { controller.removeMedia(id: $0, fileStore: fileStore) },
                onAdd: { photoSelections = $0 },
                onOpen: { id in
                    // Deferred: the attachments sheet is still dismissing, and presenting the
                    // viewer in the same runloop pass drops it on the floor.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        viewingMedia = ViewingMedia(id: id)
                    }
                }
            )
        }
        .sheet(isPresented: $showingEntryPicker) {
            if let service = services.connectionService {
                ExistingEntryPicker(service: service) { page in
                    controller.attachToExistingPage(page.id, title: page.title)
                    // And actually send it. Attaching only records which page this entry
                    // belongs to; the send used to be a separate press on the full-width
                    // button that no longer exists, so choosing a page marked the entry as
                    // needing sync and then left it there. Picking a destination is the
                    // whole action, not half of it.
                    Task { await pushToNotion() }
                }
            }
        }
        .sheet(isPresented: $showingDatePicker) {
            EntryDayPicker(current: controller.entryDate) { day in
                controller.setEntryDate(day)
            }
        }
        .task { learnTitlePrefix() }
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
        // A transcript arriving behind an open editor is invisible otherwise: the buffer is
        // deliberately not bound to the model. TextMerge keeps anything typed in the
        // meantime, so this cannot overwrite somebody mid-sentence.
        .onChange(of: services.backgroundWrites) { _, _ in
            controller.absorbExternalChanges()
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

    /// The entry itself, and nothing else.
    ///
    /// Everything around it — the date, the title, the Yours/Arranged switch, the photos, the
    /// notes about what was left out — is *about* the entry rather than part of it, and used
    /// to scroll away with it. Which meant the title of the thing you were reading vanished
    /// as soon as you read past the fold, and checking which photos were attached meant
    /// scrolling to the end and back. They are pinned now, top and bottom, and only the words
    /// move.
    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                coverBanner

                header
                    .padding(.horizontal, 20)
                    .padding(.top, coverThumbs.isEmpty ? 6 : 16)

                Group {
                    if mode == .organised, let organised = controller.organised {
                        OrganisedEntryView(organised: organised, isStale: controller.organisedIsStale)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        // Grows with the writing instead of scrolling inside itself.
                        //
                        // A TextEditor keeps a fixed height and scrolls its own contents, so
                        // once it sat inside the page's scroll view, anything past that
                        // height was cut off at its bottom edge, slicing a line in half, with
                        // the photos below. An invisible copy of the text sets the height,
                        // the editor fills it, and the page does all the scrolling.
                        ZStack(alignment: .topLeading) {
                            Text(controller.text + "\n ")
                                .writingSurface(minHeight: controller.orderedMedia.isEmpty ? 320 : 120)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .hidden()
                                .accessibilityHidden(true)
                            TextEditor(text: $controller.text)
                                .writingSurface(minHeight: 0)
                                .scrollDisabled(true)
                                .focused($writing)
                        }
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
                .padding(.horizontal, 16)
                .padding(.top, 4)

                // The photos live in the cover. The grid comes back only while picking covers
                // or choosing photos to move, which is the one time every photo is needed.
                if selectingMedia {
                    photoGrid
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                } else if let moveNotice {
                    Text(moveNotice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                }

                entryFooter
                    .padding(.horizontal, 20)
                    .padding(.top, 14)

                if hasFooterNotes {
                    footerNotes
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                }
                if mode == .organised, let organised = controller.organised,
                   !organised.dropped.isEmpty {
                    DroppedLinesNotice(organised: organised)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                }
            }
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        // How far the page is pulled down past its top, read from the scroll view itself.
        .modifier(OverscrollReader { value in if value > 0 || coverPull > 0 { coverPulled(value) } })
        // With a cover, the photo runs up under the status bar, the way a photo-led page does.
        .ignoresSafeArea(.container, edges: coverThumbs.isEmpty ? [] : .top)
        // Plain paper, the way Notes writes, rather than the grouped grey lists sit on.
        .background(Color(uiColor: .systemBackground))
    }

    private var isEditingText: Bool { writing || titling }

    /// "WWWT 10/27/26": the prefix most often used in titles like "<word> <date>", or WWWT,
    /// followed by this entry's day.
    private var suggestedTitle: String {
        let day = controller.entryDate.representativeDate()
            .formatted(.dateTime.month(.defaultDigits).day(.defaultDigits).year(.twoDigits))
        return "\(titlePrefix) \(day)"
    }

    @State private var titlePrefix = CaptureView.learnedTitlePrefix ?? "WWWT"
    /// Learned once per launch, not on every entry opened: it reads every title.
    @MainActor private static var learnedTitlePrefix: String?

    /// Learns the prefix from titles already written, such as "WWWT 8/14/26".
    private func learnTitlePrefix() {
        guard Self.learnedTitlePrefix == nil, let drafts = try? store.allDrafts() else { return }
        var counts: [String: Int] = [:]
        for draft in drafts {
            guard let title = draft.content.title,
                  let match = title.firstMatch(of: /^(.+?)\s+\d{1,2}\/\d{1,2}\/\d{2,4}$/)
            else { continue }
            counts[String(match.1), default: 0] += 1
        }
        let best = counts.max(by: { $0.value < $1.value })?.key ?? "WWWT"
        Self.learnedTitlePrefix = best
        titlePrefix = best
    }

    /// The chosen covers, the same way the journal card shows them. With none chosen, the
    /// first photo stands in, so an entry with photos always opens on one.
    private var coverThumbs: [DraftSummary.Thumb] {
        var ids = controller.coverIds
        if ids.isEmpty, let first = controller.orderedMedia.first { ids = [first.id] }
        return ids.compactMap { id in
            controller.orderedMedia.first { $0.id == id }.map {
                DraftSummary.Thumb(id: $0.id, relativePath: $0.relativePath, isVideo: $0.kind == .video)
            }
        }
    }

    /// The cover, full width, and stretchy: pull down and it grows with your finger; pull far
    /// enough and it opens full screen. Tapping it zooms into the full-screen viewer.
    @ViewBuilder
    private var coverBanner: some View {
        let covers = coverThumbs
        if !covers.isEmpty {
            let height: CGFloat = 300
            GeometryReader { geometry in
                let pull = coverPull
                Button {
                    viewingMedia = ViewingMedia(id: covers[0].id)
                } label: {
                    PhotoMosaic(
                        thumbs: covers, overflow: max(0, covers.count - 4),
                        // Full-screen resolution, so the cover is sharp at its full width.
                        fileStore: fileStore, maxPixel: 1600
                    )
                    .frame(width: geometry.size.width, height: height + pull)
                    .clipped()
                    .overlay(alignment: .bottomTrailing) { photosBadge(covers: covers) }
                }
                .buttonStyle(.plain)
                .modifier(ZoomSource(id: covers[0].id, namespace: coverZoom))
                // Grows upward with the pull, so the photo stays pinned to the top.
                .offset(y: -pull)
                // Pulling down on the cover itself stretches it too, whether or not the page
                // has room to bounce, and far enough opens it full screen.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            guard value.translation.height > 0,
                                  value.translation.height > abs(value.translation.width) else { return }
                            coverPulled(value.translation.height * 0.6)
                        }
                        .onEnded { _ in
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { coverPull = 0 }
                        }
                )
                .contextMenu {
                    Button {
                        selectingMedia = true
                        selectedMedia = Set(controller.coverIds)
                    } label: {
                        Label("Choose cover photos", systemImage: "photo.stack")
                    }
                    Button {
                        controller.setCovers([])
                    } label: {
                        Label("Clear cover photos", systemImage: "photo.badge.minus")
                    }
                }
            }
            .frame(height: height)
        }
    }

    /// The way to every photo, now that they don't sit in a grid below.
    @ViewBuilder
    private func photosBadge(covers: [DraftSummary.Thumb]) -> some View {
        if controller.orderedMedia.count > covers.count {
            Button {
                showingAttachments = true
            } label: {
                Label("\(controller.orderedMedia.count) photos", systemImage: "square.grid.2x2")
                    .font(Type.label(13, .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.55), in: Capsule())
            }
            .buttonStyle(.pressable)
            .padding(12)
        }
    }

    /// How far past the top the cover has to be pulled to open full screen.
    private static let pullToOpen: CGFloat = 110

    /// Opens the viewer once the pull goes far enough, with a tap to say so.
    private func coverPulled(_ pull: CGFloat) {
        if pull > Self.pullToOpen, coverPull <= Self.pullToOpen, viewingMedia == nil,
           let first = coverThumbs.first {
            Haptics.committed()
            viewingMedia = ViewingMedia(id: first.id)
        }
        coverPull = pull
    }

    /// The day, whether it's saved, and the title. Quiet, because the writing is the page.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    showingDatePicker = true
                } label: {
                    Text(controller.entryDate.representativeDate()
                        .formatted(.dateTime.weekday(.wide).month(.wide).day().year()).uppercased())
                        .tracking(0.8)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Changes the day this entry is filed under")
                saveStateLabel
            }
            .font(Type.caption(11.5, .semibold))
            .foregroundStyle(Brand.muted)

            // A serif for the entry's name: it's the one place the page reads like a journal
            // rather than an app.
            TextField("Title", text: $controller.title, axis: .vertical)
                .font(.system(size: 28, weight: .semibold, design: .serif))
                .textInputAutocapitalization(.sentences)
                .focused($titling)

            // The title most entries end up with anyway, offered rather than typed.
            if controller.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    controller.title = suggestedTitle
                    Haptics.picked()
                } label: {
                    Label(suggestedTitle, systemImage: "plus")
                        .font(Type.label(14, .medium))
                        .foregroundStyle(Brand.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .overlay(
                            Capsule().strokeBorder(Brand.muted.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        )
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Use \(suggestedTitle) as the title")
            }

            if controller.organised != nil {
                Picker("View", selection: $mode) {
                    ForEach(availableModes, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: mode) { Haptics.picked() }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One row of photos under the writing; the last tile counts the rest and opens them all.
    /// While selecting, every photo is shown, since anything might be the one being picked.
    private var photoGrid: some View {
        let media = controller.orderedMedia
        let limit = selectingMedia ? media.count : 4
        let shown = Array(media.prefix(limit))
        let overflow = media.count - shown.count
        return VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                    let countsRest = overflow > 0 && index == shown.count - 1
                    Button {
                        if countsRest {
                            showingAttachments = true
                        } else if selectingMedia {
                            toggleSelection(item.id)
                        } else {
                            viewingMedia = ViewingMedia(id: item.id)
                        }
                    } label: {
                        EntryPhotoTile(item: item, fileStore: fileStore)
                            .aspectRatio(1, contentMode: .fill)
                            .overlay {
                                if countsRest {
                                    Rectangle().fill(.black.opacity(0.5))
                                    Text("+\(overflow + 1)")
                                        .font(Type.label(16, .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .overlay {
                                if selectingMedia, selectedMedia.contains(item.id) {
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Brand.violet, lineWidth: 3)
                                }
                            }
                            .overlay(alignment: .topLeading) {
                                if controller.coverIds.contains(item.id) {
                                    Image(systemName: "pin.fill")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(4)
                                        .background(Brand.violet, in: Circle())
                                        .padding(4)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if controller.coverIds.contains(item.id) {
                            Button {
                                controller.toggleCover(item.id)
                            } label: {
                                Label("Remove from cover", systemImage: "photo.badge.minus")
                            }
                        } else {
                            Button {
                                controller.toggleCover(item.id)
                                Haptics.picked()
                            } label: {
                                Label("Add to cover", systemImage: "photo.badge.plus")
                            }
                        }
                        Button(role: .destructive) {
                            controller.removeMedia(id: item.id, fileStore: fileStore)
                        } label: {
                            Label("Remove from entry", systemImage: "trash")
                        }
                    }
                }
            }
            mediaSelectionBar
        }
    }

    /// When the entry was started, and how many photos it holds.
    private var entryFooter: some View {
        HStack(spacing: 14) {
            Label(controller.createdAt.formatted(date: .omitted, time: .shortened), systemImage: "clock")
            if !controller.orderedMedia.isEmpty {
                Button {
                    showingAttachments = true
                } label: {
                    Label("\(controller.orderedMedia.count)", systemImage: "photo")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("See all \(controller.orderedMedia.count) photos and videos")
            }
        }
        .font(Type.caption(12))
        .foregroundStyle(Brand.muted)
    }

    /// Everything below is *about* the entry rather than part of it, so it sits together on
    /// its own ground instead of trailing off as loose grey text.
    private var footerNotes: some View {
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

            // Right after a sync this is where you're already looking, so put the way to go
            // and see the result here rather than only in a menu.
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
        .padding(12)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
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

                // Covers in the order the photos sit in the entry, so picking several in one go
                // gives a predictable grid.
                Button {
                    let chosen = controller.orderedMedia.map(\.id).filter { selectedMedia.contains($0) }
                    controller.setCovers(chosen)
                    Haptics.picked()
                    endSelection()
                } label: {
                    Label("Cover", systemImage: "photo.badge.checkmark")
                }
                .disabled(selectedMedia.isEmpty)

                Button {
                    showingMoveSheet = true
                } label: {
                    Label("Move \(selectedMedia.count)", systemImage: "arrow.right.doc.on.clipboard")
                }
                .disabled(selectedMedia.isEmpty)
            }
            .font(.footnote)
        } else if let moveNotice {
            // Selecting and seeing them all live in the "…" menu and on the last tile, so the
            // only thing left to say here is what a move just did.
            Text(moveNotice)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .transition(.opacity)
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
            // Deliberately not a count. A long recording is stored as several chunks so a
            // crash costs one of them rather than all of them, but the person pressed record
            // once: telling them "10 recordings saved" reports the implementation as though
            // it were something they did.
            Text("Your recording is saved, waiting to transcribe")
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
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                PhotosPicker(
                    selection: $photoSelections, maxSelectionCount: nil,
                    matching: .any(of: [.images, .videos])
                ) {
                    CompactAction(symbol: "photo.on.rectangle.angled", title: "Photos", tint: Brand.muted, accent: Brand.Mode.photo)
                }
                // The only control in this row that is not a Button, so it was the only one
                // with no press treatment: no shrink, no dim, no tap back. That is most of
                // what "it feels like a picture rather than a button" is.
                .buttonStyle(.toolbarAction)
                .disabled(recorder.isRecording)

                Button {
                    Haptics.committed()
                    beginRecording()
                } label: {
                    CompactAction(symbol: "mic", title: "Record", tint: Brand.muted, accent: Color(uiColor: .systemRed))
                }
                .buttonStyle(.toolbarAction)
                .disabled(recorder.isRecording)

                // Organising sits beside formatting rather than replacing it. Formatting may
                // not change a word; organising may not lose a thought. Two jobs, two
                // guarantees, two buttons.
                Button {
                    Task { await organise() }
                } label: {
                    CompactAction(
                        symbol: "sparkles",
                        title: "Arrange",
                        // The one coloured control: it's the thing only this app does.
                        tint: Brand.violet,
                        busy: isOrganising
                    )
                }
                .buttonStyle(.toolbarAction)
                // Disabled while it runs, not just visually busy. The coordinator already
                // refuses a second run for the same draft, so extra taps were harmless — but
                // a button that accepts a press and does nothing is how somebody learns the
                // app is broken.
                .disabled(!canOrganise || isOrganising)

                Button {
                    showingSendSheet = true
                } label: {
                    CompactAction(symbol: "square.and.arrow.up", title: "Send", tint: Brand.muted, accent: Brand.Mode.text)
                }
                .buttonStyle(.toolbarAction)
                .disabled(controller.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .overlay { if recorder.isActive { recordingCapsule } }
            .animation(.easeOut(duration: 0.18), value: recorder.isActive)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .top) {
            Rectangle().fill(Brand.edge).frame(height: 0.5)
        }
    }

    /// The bar that replaces the action row while a recording is going.
    ///
    /// Two controls now rather than one. Stop used to be the whole capsule, which made it the
    /// thing you hit by reflex when you only wanted to think for a moment — and stopping is
    /// the one move you cannot take back into the same recording.
    private var recordingCapsule: some View {
        HStack(spacing: 10) {
            Button {
                Haptics.committed()
                togglePause()
            } label: {
                Image(systemName: recorder.isPaused ? "mic.fill" : "pause.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recorder.isPaused ? "Resume recording" : "Pause recording")

            if recorder.isPaused {
                // A waveform that has stopped moving looks like a bug. Say the word instead.
                Text("Paused")
                    .font(Type.label(13))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LiveWaveform(levels: recorder.levels, tint: .white)
                    .frame(height: 20).frame(maxWidth: .infinity)
            }

            Text(elapsedLabel).font(Type.mono(13)).foregroundStyle(.white)

            Button {
                Haptics.committed()
                stopRecording()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop recording")
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(
            recorder.isPaused ? AnyShapeStyle(Brand.muted) : AnyShapeStyle(Brand.gradient),
            in: Capsule()
        )
    }

    /// Whether there is anywhere to send to at all. Nil when no backend is configured, which
    /// is how the app ships and therefore what every new user sees.
    private var hasDestination: Bool { services.connectionService != nil }

    private var canSend: Bool {
        // The destination check was missing, so on a fresh install the biggest, brightest
        // control on the screen read "Send to Notion", was fully enabled, and failed when
        // pressed. For someone who has just been told on the first-run screen that Notion is
        // optional and nothing is uploaded, that is the app immediately contradicting itself
        // and then not working.
        hasDestination
            && controller.needsSync
            && !controller.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && services.sync?.isSyncing(controller.draftId) != true
    }

    private var sendSheet: some View {
        SendSheet(
            markdown: EntryMarkdown.render(
                title: controller.title,
                day: controller.entryDate,
                organised: controller.organised,
                text: controller.text
            ),
            subject: EntryMarkdown.heading(
                title: controller.title, day: controller.entryDate
            ),
            // Absent rather than disabled when nothing is connected. A row that exists only
            // to say a service is unavailable is an advertisement for the service.
            notion: services.connectionService == nil ? nil : SendSheet.Notion(
                actionTitle: sendTitle,
                canSend: canSend,
                isSending: services.sync?.isSyncing(controller.draftId) == true,
                send: { Task { await pushToNotion() } },
                chooseExistingPage: { showingEntryPicker = true }
            )
        )
    }

    /// Labels a row inside the send sheet now, not the whole screen's primary action.
    private var sendTitle: String {
        if !hasDestination { return "Notion isn\u{2019}t connected" }
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
                    "Saved \u{00B7} waiting to transcribe",
                    systemImage: "waveform"
                )
                .foregroundStyle(Brand.waiting)
                .lineLimit(1)
            case .saved:
                Text("\u{00B7} Saved")
                    .foregroundStyle(Brand.muted)
            }
        }
        .font(Type.caption(12.5, .medium))
        .transition(.opacity)
        .animation(.easeOut(duration: 0.2), value: controller.pendingTranscriptionCount)
    }



    /// Transcription and sync fail for the same reasons and phrase them the same way, so
    /// showing both verbatim prints the identical sentence twice. Deduplicated, order kept.
    private var statusMessages: [String] {
        var seen = Set<String>()
        var messages: [String] = []
        let candidates = [
            // First, because it is the only one describing something happening right now.
            // Organising is two model calls and can take most of a minute against a server
            // that has to wake up, and a spinner on a 46-point button is not enough to
            // explain a wait that long.
            isOrganising ? "Grouping what goes together\u{2026}" : nil,
            recorder.interruptionNotice,
            failedUploadMessage,
            controller.pendingTranscriptionCount > 0 ? services.transcriptions?.blockedReason : nil,
            services.organising?.blockedReason,
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
            SyncStagesView(progress: step, absent: absentStages)
        }
    }

    /// Stages this entry has nothing to send for, so they can be shown as skipped rather
    /// than as work that never starts.
    private var absentStages: Set<SyncProgress.Stage> {
        var absent: Set<SyncProgress.Stage> = []
        if !controller.orderedMedia.contains(where: { $0.kind == .photo }) { absent.insert(.photos) }
        if !controller.orderedMedia.contains(where: { $0.kind == .video }) { absent.insert(.videos) }
        return absent
    }


    private var elapsedLabel: String {
        let total = Int(recorder.elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Only offer a pane that has something in it. A tab that shows an empty state is worse
    /// than no tab, because it reads as something broken rather than something unused.
    private var availableModes: [Mode] {
        var modes: [Mode] = [.raw]
        if controller.organised != nil { modes.append(.organised) }
        return modes
    }

    /// Names the attachments that did not upload, and why, rather than leaving somebody to
    /// work out which of nine thumbnails is the problem.
    private var failedUploadMessage: String? {
        // A video kept on the phone is not an upload failure and must not be reported as one.
        // It has no retry to offer and nothing went wrong; it is a video too long for the
        // destination to take. The attachments screen explains it properly.
        let failed = controller.orderedMedia.filter {
            $0.uploadStatus == .failed && !$0.isTooLargeToSend
        }
        guard !failed.isEmpty else { return nil }

        let photos = failed.filter { $0.kind == .photo }.count
        let videos = failed.filter { $0.kind == .video }.count
        var parts: [String] = []
        if photos > 0 { parts.append("\(photos) photo\(photos == 1 ? "" : "s")") }
        if videos > 0 { parts.append("\(videos) video\(videos == 1 ? "" : "s")") }

        // One reason when they all share it, which is the common case — the network went, or
        // the destination refused everything. Listing it nine times says nothing extra.
        let reasons = Set(failed.compactMap(\.uploadError))
        let why = reasons.count == 1 ? " \(reasons.first!)" : ""
        return "\(parts.joined(separator: " and ")) didn\u{2019}t upload, marked in red.\(why)"
    }

    private var isOrganising: Bool {
        services.organising?.isOrganising(controller.draftId) == true
    }

    /// False while a recording is still waiting to be transcribed: arranging a transcript
    /// that is about to grow would produce half a day that looks finished. See ADR-002.
    private var canOrganise: Bool {
        services.organising?.canOrganise(draftId: controller.draftId) == true
            && services.organising?.isOrganising(controller.draftId) != true
    }

    private func organise() async {
        guard let organising = services.organising else { return }
        let outcome = await organising.organise(draftId: controller.draftId)
        controller.reload()
        switch outcome {
        case .organised:
            Haptics.committed()
            withAnimation { mode = .organised }
        case .deferred, .failed:
            // The reason is already on the coordinator, and `statusMessages` reads it from
            // there. Keeping one source means the banner cannot disagree with the state.
            Haptics.failed()
        default:
            break
        }
    }

    private var dayLabel: String {
        controller.entryDate.representativeDate()
            .formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    // MARK: - Actions

    /// Wires the recorder to this draft, then starts it.
    ///
    /// Each chunk is registered the moment it closes, so a crash partway through costs the
    /// chunk in progress rather than the whole recording.
    private func beginRecording() {
        recorder.reserveChunk = {
            try fileStore.reserve(preferredName: "dictation", extension: "m4a")
        }
        recorder.onChunkFinished = { file, duration in
            controller.registerChunk(file, duration: duration, fileStore: fileStore)
        }
        recorder.activityName = recordingName
        Task { await recorder.start() }
    }

    /// What the Lock Screen calls this recording. The entry's title when it has one, its
    /// date otherwise — never its contents, which have no business on a lock screen.
    private var recordingName: String {
        let title = controller.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        return controller.entryDate.representativeDate()
            .formatted(.dateTime.weekday(.wide).month().day())
    }

    private func togglePause() {
        if recorder.isPaused {
            Task { await recorder.resume() }
        } else {
            // Everything said so far is closed and registered by the time this returns, so
            // the app can be killed from here without costing a word.
            recorder.pause()
        }
    }

    private func stopRecording() {
        // Every chunk, the last one included, was written and registered as it closed. By the
        // time this returns the audio is already safe, so there is nothing to persist here.
        guard recorder.stop() != nil else { return }
        Haptics.landed()
        // Transcription is a separate, failable step. If it never succeeds the recording is
        // still on disk and still queued. See ADR-002.
        Task {
            await services.drainTranscriptions()
            // The queue writes straight to the model, so the editor has to be told. Without
            // this the transcript is invisible and the next keystroke overwrites it.
            controller.absorbExternalChanges()
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
/// One action in the entry's toolbar: an icon and its name, no tile behind it.
///
/// They used to sit on four differently coloured tiles, which read as four separate features
/// rather than one toolbar. Plain and grey now, so the one coloured action stands out.
struct CompactAction: View {
    let symbol: String
    /// Said out loud, under the icon.
    ///
    /// Five tinted squares in a row is a puzzle, not a toolbar. Two of these are AI actions
    /// whose icons cannot possibly carry the distinction between them, and an icon nobody
    /// can name is a button nobody presses.
    let title: String
    let tint: Color
    /// Swaps the icon for a spinner.
    ///
    /// Organising a long entry is two model calls and can take the better part of a minute
    /// against a server that has to wake up first. A static icon swap was not enough to read
    /// as "working" — it looked like nothing had happened, so people pressed it again.
    var busy: Bool = false
    /// The colour it lights up in while pressed. Defaults to its resting tint.
    var accent: Color? = nil

    @Environment(\.actionPressed) private var pressed
    @Environment(\.isEnabled) private var isEnabled

    private var color: Color { pressed ? (accent ?? tint) : tint }

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tint)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 19, weight: pressed ? .semibold : .regular))
                        .foregroundStyle(color)
                        .symbolEffect(.bounce, value: pressed)
                }
            }
            .frame(width: 52, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill((accent ?? tint).opacity(pressed ? 0.2 : 0))
            )
            .frame(maxWidth: .infinity)

            Text(title)
                .font(Type.caption(10.5, pressed ? .semibold : .medium))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(.easeOut(duration: 0.12), value: pressed)
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

/// A photo in the entry, cropped to whatever space it's given. The image is an overlay on a
/// flexible colour so a wide photo can't widen the grid it sits in.
struct EntryPhotoTile: View {
    let item: MediaItem
    let fileStore: MediaFileStore
    var maxPixel: CGFloat = 300
    @State private var image: UIImage?

    var body: some View {
        Brand.surface
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if item.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 3)
                        .padding(6)
                }
            }
            .task(id: item.id) {
                image = await ThumbnailCache.shared.thumbnail(for: item, fileStore: fileStore, maxPixel: maxPixel)
            }
    }
}

/// Marks the view a full-screen photo zooms out of. iOS 18 and later; before that the
/// viewer slides up as a normal full-screen cover.
struct ZoomSource: ViewModifier {
    let id: UUID
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

/// The other half of `ZoomSource`, on the presented viewer.
struct ZoomFrom: ViewModifier {
    let id: UUID
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}

/// Reports how far a scroll view is pulled down past its top, 0 when it isn't. iOS 18 and
/// later; before that the cover simply doesn't stretch.
struct OverscrollReader: ViewModifier {
    let changed: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(-(geometry.contentOffset.y + geometry.contentInsets.top), 0)
            } action: { _, value in
                changed(value)
            }
        } else {
            content
        }
    }
}
