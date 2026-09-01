import CodenamePromiseCore
import PhotosUI
import SwiftUI

/// The front door: put a thing in the tray.
///
/// The concept's insight is that the fastest capture is one where you do not first have to
/// decide what you are making. There is no "new entry" step here — you talk, or type, or pick
/// a photo, and hit Dump it.
///
/// Structurally this is a thin shell over what already existed. A dump *is* an `EntryDraft`,
/// which has always allowed several per day with its own destination page (ADR-006), so
/// nothing about the store, sync, export or the day-grouped journal had to change to support
/// it. The compose state below is deliberately the only new concept.
struct DumpView: View {
    /// Mirrors how much is staged, so the tab bar's tray can react to it.
    @Binding var stagedCount: Int
    /// Poked on landing so the whole app flinches, not just this screen.
    let impact: DumpImpact
    /// Called with the draft a finished dump created, so the caller can open it.
    let onDumped: (UUID) -> Void

    @Environment(AppServices.self) private var services

    @State private var text = ""
    @State private var recorder = AudioRecorder()
    @State private var picked: [PhotosPickerItem] = []
    @State private var staged: [StagedMedia] = []
    @State private var pendingAudio: (data: Data, duration: TimeInterval)?
    @State private var showingPhotos = false
    @State private var showingVideos = false
    @State private var showingDestination = false
    /// An existing Notion page to append to, instead of making a new one.
    @State private var appendTo: NotionPage?
    @State private var connection: NotionConnectionStatus?
    @State private var flight: [DumpFlight.Piece] = []
    @State private var flightPhase: DumpFlight.Phase = .idle
    /// The button winding up as the pieces converge on it.
    @State private var charging = false
    @State private var status: Status = .composing
    @FocusState private var writing: Bool

    /// Media chosen but not yet committed to a draft. Held as bytes so "Dump it" is the
    /// moment anything is written — before that, nothing has been created.
    struct StagedMedia: Identifiable {
        let id = UUID()
        let url: URL
        let kind: MediaKind
    }

    enum Status: Equatable {
        case composing
        case dumping
        case dumped(String)
        case failed(String)
    }

    private var hasSomethingToDump: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !staged.isEmpty
            || pendingAudio != nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                composer
                modeButtons
                destinationRow
                dumpButton
                statusLine
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            // A ScrollView sizes to its content, so `maxHeight: .infinity` does nothing
            // inside one - the stack stayed pinned to the top with a void beneath it.
            // Matching the container's height is what lets it sit optically centred, and it
            // still scrolls once the keyboard or a long dump makes it taller.
            .containerRelativeFrame(.vertical) { height, _ in height }
        }
        .background(Brand.ground)
        .overlay { flightOverlay }
        .scrollDismissesKeyboard(.interactively)
        // iOS gives a plain TextEditor no way out: with no return key to dismiss and no
        // accessory, the only exit is tapping some arbitrary blank area.
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { writing = false }
                    .font(Type.label(15, .semibold))
            }
        }
        .photosPicker(isPresented: $showingPhotos, selection: $picked,
                      maxSelectionCount: nil, matching: .images)
        .photosPicker(isPresented: $showingVideos, selection: $picked,
                      maxSelectionCount: nil, matching: .videos)
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            Task { await stage(items) }
        }
        .onChange(of: staged.count) { _, _ in syncStagedCount() }
        .onChange(of: pendingAudio != nil) { _, _ in syncStagedCount() }
        .onDisappear { stagedCount = 0 }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("What's on your mind?")
                        .font(Type.body(17))
                        .foregroundStyle(Brand.muted)
                        .padding(.top, 14)
                        .padding(.leading, 16)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(Type.body(17))
                    .lineSpacing(5)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .focused($writing)
            }
            .frame(minHeight: 190)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(writing ? Brand.violet.opacity(0.5) : Color.clear, lineWidth: 2)
            )
            .animation(.easeOut(duration: 0.15), value: writing)

            if recorder.isRecording { recordingBar }
            if !staged.isEmpty || pendingAudio != nil { stagedStrip }
        }
    }

    private var recordingBar: some View {
        Button {
            Haptics.committed()
            stopRecording()
        } label: {
            HStack(spacing: 12) {
                LiveWaveform(levels: recorder.levels, tint: .white)
                    .frame(height: 24)
                    .frame(maxWidth: .infinity)
                Text(elapsed).font(Type.mono(14)).foregroundStyle(.white)
                Image(systemName: "stop.fill").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(Brand.gradient, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// What is about to be dumped, and nothing is written until it is.
    private var stagedStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if pendingAudio != nil {
                    stagedChip(icon: "waveform", tint: Brand.Mode.voice, label: "Recording") {
                        pendingAudio = nil
                    }
                }
                ForEach(staged) { item in
                    stagedChip(
                        icon: item.kind == .video ? "video.fill" : "photo.fill",
                        tint: item.kind == .video ? Brand.Mode.video : Brand.Mode.photo,
                        label: item.kind == .video ? "Video" : "Photo"
                    ) {
                        staged.removeAll { $0.id == item.id }
                        try? FileManager.default.removeItem(at: item.url)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func stagedChip(
        icon: String, tint: Color, label: String, remove: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            Text(label).font(Type.caption(12.5))
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(tint.opacity(0.12), in: Capsule())
    }

    // MARK: - Modes

    /// One confetti colour each, which is the mark's whole idea: different kinds of thing,
    /// same tray.
    private var modeButtons: some View {
        HStack(spacing: 14) {
            modeButton("Text", "text.alignleft", Brand.Mode.text) {
                writing = true
            }
            modeButton("Voice", "mic.fill", Brand.Mode.voice) {
                Haptics.committed()
                Task { await recorder.start() }
            }
            modeButton("Photo", "photo.fill", Brand.Mode.photo) {
                showingPhotos = true
            }
            modeButton("Video", "video.fill", Brand.Mode.video) {
                showingVideos = true
            }
        }
    }

    private func modeButton(
        _ title: String, _ symbol: String, _ tint: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 56, height: 56)
                    .background(tint.opacity(0.13), in: Circle())
                Text(title)
                    .font(Type.caption(12, .medium))
                    .foregroundStyle(Brand.muted)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.pressable)
        .disabled(recorder.isRecording)
        .opacity(recorder.isRecording ? 0.4 : 1)
    }

    /// Sits just above the bottom edge rather than down in the tab bar, so the impact is
    /// actually on screen - a shockwave clipped by the view's bounds is a shockwave nobody
    /// sees.
    private var flightOverlay: some View {
        GeometryReader { geo in
            DumpFlight(
                pieces: flight,
                // The Dump it button, which is what they are being thrown into.
                destination: CGPoint(x: geo.size.width / 2, y: geo.size.height * 0.78),
                phase: flightPhase,
                size: geo.size
            )
        }
    }

    // MARK: - Destination

    /// Where this dump is going, before it goes.
    ///
    /// The concept did not have this because it did not know the app already supports
    /// appending to a page you pick rather than always making a new one. Choosing after the
    /// fact means going and finding the entry again; choosing here is one tap and it is
    /// visible without being asked for.
    private var destinationRow: some View {
        Button {
            showingDestination = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: appendTo == nil ? "doc.badge.plus" : "text.append")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.violet)

                VStack(alignment: .leading, spacing: 1) {
                    Text(destinationTitle)
                        .font(Type.caption(13, .semibold))
                        .foregroundStyle(Brand.ink)
                        .lineLimit(1)
                    Text(destinationDetail)
                        .font(Type.caption(11.5))
                        .foregroundStyle(Brand.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Brand.muted)
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.pressable)
        .sheet(isPresented: $showingDestination) {
            DumpDestinationSheet(
                connection: connection,
                appendTo: $appendTo,
                connectionService: services.connectionService
            )
        }
        .task {
            // Read once per appearance rather than per keystroke; the answer only changes
            // in Settings.
            connection = try? await services.connectionService?.status()
        }
    }

    private var destinationTitle: String {
        if let appendTo { return "Add to \u{201C}\(appendTo.title)\u{201D}" }
        guard let connection, connection.ready else { return "Saved on this device" }
        return connection.databaseTitle ?? "Your Notion database"
    }

    private var destinationDetail: String {
        if appendTo != nil { return "Appends to that page instead of making a new one" }
        guard let connection else { return "Checking Notion\u{2026}" }
        if !connection.configurable { return "Notion isn\u{2019}t set up on the server" }
        if !connection.connected { return "Connect Notion in Settings to sync" }
        if !connection.ready { return "Pick a database in Settings" }
        return "A new page, each dump its own"
    }

    // MARK: - Dump

    private var dumpButton: some View {
        Button {
            dump()
        } label: {
            Group {
                if status == .dumping {
                    ProgressView().tint(.white)
                } else {
                    Text("Dump it").font(Type.label(17, .semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(
                hasSomethingToDump ? AnyShapeStyle(Brand.gradient)
                                   : AnyShapeStyle(Brand.muted.opacity(0.2)),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .shadow(
                color: Brand.violet.opacity(charging ? 0.9 : (hasSomethingToDump ? 0.34 : 0)),
                radius: charging ? 34 : 14, y: 6
            )
            // Winding up: it swells and its glow builds as the pieces converge, so the blast
            // reads as something the button did rather than something that happened near it.
            .scaleEffect(charging ? 1.07 : 1)
            .animation(.easeIn(duration: 0.34), value: charging)
        }
        .buttonStyle(.pressablePrimary)
        .disabled(!hasSomethingToDump || status == .dumping)
        .animation(.easeOut(duration: 0.18), value: hasSomethingToDump)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .composing:
            // Says where it goes before you commit, not after.
            // States what is guaranteed, not what is hoped for. Saving is local and
            // certain; reaching Notion is neither, and the journal says so per entry.
            Label("Saved here first, then sent to Notion", systemImage: "tray.and.arrow.down")
                .font(Type.caption(12.5))
                .foregroundStyle(Brand.muted)
        case .dumping:
            EmptyView()
        case .dumped(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(Type.caption(13, .semibold))
                .foregroundStyle(Brand.reached)
                .transition(.opacity)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(Type.caption(13, .semibold))
                .foregroundStyle(Brand.failed)
        }
    }

    // MARK: - Actions

    private var elapsed: String {
        let total = Int(recorder.elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func stopRecording() {
        guard let finished = recorder.stop() else { return }
        pendingAudio = (finished.data, finished.duration)
    }

    private func stage(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                staged.append(StagedMedia(url: movie.url, kind: .video))
            } else if let data = try? await item.loadTransferable(type: Data.self) {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("dump-\(UUID().uuidString).jpg")
                if (try? data.write(to: url, options: .atomic)) != nil {
                    staged.append(StagedMedia(url: url, kind: .photo))
                }
            }
        }
        picked = []
    }

    /// The only moment anything is written.
    ///
    /// Order matters and follows the same discipline as everywhere else: the draft and its
    /// bytes are committed first, and anything that can fail — transcription, sync — happens
    /// afterwards and can never cost the capture (ADR-001, ADR-002).
    /// One flying piece per thing captured, starting from roughly where it sat on screen.
    private func syncStagedCount() {
        stagedCount = staged.count + (pendingAudio != nil ? 1 : 0)
    }

    private func flightPieces() -> [DumpFlight.Piece] {
        var pieces: [DumpFlight.Piece] = []
        var delay = 0.0
        func add(_ symbol: String, _ tint: Color, _ x: CGFloat) {
            // Unit coordinates: the mode-button row, wherever it happens to be.
            pieces.append(.init(symbol: symbol, tint: tint,
                                originUnit: CGPoint(x: x, y: 0.58), delay: delay))
            delay += 0.05
        }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add("text.alignleft", Brand.Mode.text, 0.16)
        }
        if pendingAudio != nil { add("mic.fill", Brand.Mode.voice, 0.38) }
        for item in staged.prefix(4) {
            add(item.kind == .video ? "video.fill" : "photo.fill",
                item.kind == .video ? Brand.Mode.video : Brand.Mode.photo,
                0.62 + CGFloat(pieces.count % 2) * 0.22)
        }
        return pieces
    }

    private func dump() {
        guard let store = services.store, let files = services.files else { return }
        status = .dumping

        do {
            let draft = try store.createDraft()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { try store.updateRawText(trimmed, for: draft) }

            for item in staged {
                _ = try store.attachMedia(from: item.url, kind: item.kind, to: draft, fileStore: files)
                try? FileManager.default.removeItem(at: item.url)
            }

            if let pendingAudio {
                try store.attachAudioCapture(
                    data: pendingAudio.data, fileExtension: "m4a",
                    durationSeconds: pendingAudio.duration, to: draft, fileStore: files
                )
            }

            if let appendTo {
                draft.syncState(for: .notion)
                    .attachToExistingPage(appendTo.id, title: appendTo.title)
                try store.flush()
            }

            Haptics.landed()
            let created = draft.id

            // Everything below here is optional and may fail freely.
            Task { await services.drainTranscriptions() }

            // What was captured, thrown toward the tray. Built before the state is cleared,
            // because it describes what was just dumped.
            flight = flightPieces()
            text = ""
            staged = []
            pendingAudio = nil
            appendTo = nil
            writing = false
            status = .composing

            Task {
                // One frame at rest first. Inserting the pieces with the phase already
                // flipped gives SwiftUI no "from" state, so the swirl simply never played -
                // which is why the last build looked like a freeze and then a bang.
                try? await Task.sleep(for: .milliseconds(20))
                flightPhase = .falling
                charging = true

                // They converge while the button winds up. Shorter than it was: past about
                // a third of a second the charge stops building tension and starts being a
                // wait.
                try? await Task.sleep(for: .milliseconds(330))
                Haptics.thud()
                impact.blast()
                charging = false
                flightPhase = .impact

                // Leave *on* the blast rather than after it. The flash and swell live on the
                // root view, not this screen, so they keep playing across the tab change -
                // the transition rides the explosion instead of waiting for it to finish.
                syncStagedCount()
                onDumped(created)

                // Cleaned up after the navigation, so nothing pops before the screen leaves.
                try? await Task.sleep(for: .milliseconds(260))
                flight = []
                flightPhase = .idle
            }
        } catch {
            Haptics.failed()
            status = .failed(error.localizedDescription)
        }
    }

}
