import AVFoundation
import CodenamePromiseCore
import SwiftUI

/// A deleted entry, shown in full but not editable: its writing, every photo and video, and
/// any recordings, with Restore and Delete now within reach.
///
/// Reads the entry once into plain values and never writes to it, so looking at something in
/// Recently Deleted can't count as an edit or move `updatedAt` (ADR-016). Holding values
/// rather than the model also means a permanent delete can't leave this screen reading a
/// model that's gone (ADR-009a). The one place models are read again is the full-screen
/// viewer, which fetches them fresh when it opens.
struct DeletedEntryView: View {
    let store: DraftStore
    let fileStore: MediaFileStore
    let id: UUID
    /// The caller does the restoring and deleting, and takes this screen away as it does.
    let onRestore: () -> Void
    let onDelete: () -> Void

    @AppStorage(JournalFont.storageKey) private var journalFont: JournalFont = .sans
    @State private var entry: Snapshot?
    @State private var viewingMedia: ViewingMedia?
    @State private var confirmingDelete = false
    @State private var player = RecordingPlayer()

    struct Snapshot {
        let title: String?
        let day: String
        let deleted: String
        let daysLeft: Int
        let markdown: String
        let media: [DraftSummary.Thumb]
        let recordings: [Recording]
    }

    struct Recording: Identifiable {
        let id: UUID
        let relativePath: String
        let recordedAt: Date
        let duration: Double
        /// Words not yet in the entry's text. Once a transcript is merged it's already in the
        /// writing above, so showing it again would only repeat it.
        let pendingWords: String?
        let status: TranscriptionStatus
        let merged: Bool
    }

    var body: some View {
        List {
            if let entry {
                header(entry)
                writing(entry)
                if !entry.media.isEmpty { media(entry) }
                if !entry.recordings.isEmpty { recordings(entry) }
            } else {
                ContentUnavailableView(
                    "This entry is gone",
                    systemImage: "trash",
                    description: Text("It may have been restored or deleted somewhere else.")
                )
                .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Brand.ground)
        .navigationTitle("Deleted Entry")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if entry != nil { actions }
        }
        .confirmationDialog(
            "Delete this entry for good?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete for good", role: .destructive) {
                player.stop()
                onDelete()
            }
        } message: {
            Text("Its writing, photos and recordings are removed from this iPhone. This can\u{2019}t be undone.")
        }
        .fullScreenCover(item: $viewingMedia) { viewing in
            // Fetched as it opens rather than held, for the reason in the type comment.
            let items = (try? store.draft(id: id))?.orderedMedia ?? []
            if items.isEmpty {
                Color.black.ignoresSafeArea().onAppear { viewingMedia = nil }
            } else {
                MediaViewer(items: items, fileStore: fileStore, selection: viewing.id)
            }
        }
        .task { load() }
        .onDisappear { player.stop() }
    }

    // MARK: Sections

    private func header(_ entry: Snapshot) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.title ?? "Untitled entry")
                    .font(Type.title(24))
                    .foregroundStyle(entry.title == nil ? Brand.muted : Brand.ink)
                Text(entry.day)
                    .font(Type.label(15, .semibold))
                    .foregroundStyle(Brand.violet)
                Text("Deleted \(entry.deleted) \u{00B7} \(Self.leftLabel(entry.daysLeft))")
                    .font(Type.caption())
                    .foregroundStyle(Brand.muted)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func writing(_ entry: Snapshot) -> some View {
        let document = RichDocument(blocks: Self.unfolded(RichDocument(markdown: entry.markdown).blocks))
        let plain = document.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        Section("Writing") {
            if plain.isEmpty {
                Text("No writing in this entry.")
                    .font(Type.body(15))
                    .foregroundStyle(Brand.muted)
            } else if #available(iOS 26.0, *) {
                Text(RichText.attributed(document, look: RichText.Look(font: journalFont)))
                    .lineSpacing(7)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                Text(plain)
                    .font(Type.journal())
                    .foregroundStyle(Brand.ink)
                    .lineSpacing(7)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }
    }

    private func media(_ entry: Snapshot) -> some View {
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                ForEach(entry.media) { thumb in
                    Button {
                        viewingMedia = ViewingMedia(id: thumb.id)
                    } label: {
                        PhotoTile(thumb: thumb, fileStore: fileStore, maxPixel: 360)
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(thumb.isVideo ? "Video" : "Photo")
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text(Self.mediaLabel(entry.media))
        }
    }

    private func recordings(_ entry: Snapshot) -> some View {
        Section("Recordings") {
            ForEach(entry.recordings) { recording in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        let playable = fileStore.exists(recording.relativePath)
                        Button {
                            player.toggle(recording.id, url: fileStore.url(for: recording.relativePath))
                        } label: {
                            Image(systemName: player.playing == recording.id ? "stop.fill" : "play.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(playable ? Brand.Mode.voice : Brand.muted.opacity(0.4), in: Circle())
                        }
                        .buttonStyle(.borderless)
                        .disabled(!playable)
                        .accessibilityLabel(player.playing == recording.id ? "Stop" : "Play recording")

                        VStack(alignment: .leading, spacing: 2) {
                            Text(recording.recordedAt.formatted(date: .omitted, time: .shortened))
                                .font(Type.label(15, .semibold))
                                .foregroundStyle(Brand.ink)
                            Text(Self.recordingDetail(recording, playable: playable))
                                .font(Type.caption())
                                .foregroundStyle(Brand.muted)
                        }
                    }
                    if let words = recording.pendingWords {
                        Text(words)
                            .font(Type.journal(16))
                            .foregroundStyle(Brand.ink)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Label("Delete now", systemImage: "trash")
                    .font(Type.label(16))
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.bordered)
            .tint(Brand.failed)

            Button {
                player.stop()
                onRestore()
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
                    .font(Type.label(16))
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.violet)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }

    // MARK: Loading

    /// Reads only. Nothing on this screen calls a mutating store method except through the
    /// two buttons, which hand off to the caller.
    private func load() {
        guard let draft = try? store.draft(id: id), let deletedAt = draft.deletedAt else {
            entry = nil
            return
        }
        let title = draft.content.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let goes = deletedAt.addingTimeInterval(DraftStore.trashRetention)
        entry = Snapshot(
            title: (title?.isEmpty ?? true) ? nil : title,
            day: draft.entryDate.representativeDate().formatted(.dateTime.weekday(.wide).month(.wide).day().year()),
            deleted: deletedAt.formatted(.dateTime.month(.abbreviated).day()),
            daysLeft: max(0, Int(ceil(goes.timeIntervalSinceNow / 86_400))),
            markdown: draft.content.rawText,
            media: draft.orderedMedia.map {
                DraftSummary.Thumb(id: $0.id, relativePath: $0.relativePath, isVideo: $0.kind == .video)
            },
            recordings: draft.orderedAudioCaptures.map { capture in
                let words = capture.transcript?.trimmingCharacters(in: .whitespacesAndNewlines)
                return Recording(
                    id: capture.id,
                    relativePath: capture.relativePath,
                    recordedAt: capture.recordedAt,
                    duration: capture.durationSeconds,
                    pendingWords: capture.mergedIntoDraftAt == nil && !(words ?? "").isEmpty ? words : nil,
                    status: capture.transcriptionStatus,
                    merged: capture.mergedIntoDraftAt != nil
                )
            }
        )
    }

    /// Folded toggle headings opened out, so a preview meant to show everything can't tuck
    /// lines away behind an arrow nobody can tap here.
    private static func unfolded(_ blocks: [RichDocument.Block]) -> [RichDocument.Block] {
        blocks.flatMap { block -> [RichDocument.Block] in
            var head = block
            let tucked = head.folded ?? []
            head.folded = nil
            return [head] + unfolded(tucked)
        }
    }

    // MARK: Labels

    static func leftLabel(_ days: Int) -> String {
        "\(days) \(days == 1 ? "day" : "days") left"
    }

    private static func mediaLabel(_ media: [DraftSummary.Thumb]) -> String {
        let videos = media.filter(\.isVideo).count
        let photos = media.count - videos
        var parts: [String] = []
        if photos > 0 { parts.append("\(photos) \(photos == 1 ? "photo" : "photos")") }
        if videos > 0 { parts.append("\(videos) \(videos == 1 ? "video" : "videos")") }
        return parts.joined(separator: " and ")
    }

    private static func recordingDetail(_ recording: Recording, playable: Bool) -> String {
        let length = Duration.seconds(recording.duration)
            .formatted(.time(pattern: recording.duration >= 3600 ? .hourMinuteSecond : .minuteSecond))
        let state: String
        if recording.merged {
            state = "Words are in the writing above"
        } else {
            switch recording.status {
            case .transcribed: state = "Not yet added to the writing"
            case .pending, .transcribing, .failed: state = "Not written out yet"
            }
        }
        return playable ? "\(length) \u{00B7} \(state)" : state
    }
}

/// Plays one recording at a time, and resets its button when the recording ends.
@MainActor
@Observable
private final class RecordingPlayer {
    private(set) var playing: UUID?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private let finish = FinishRelay()

    init() {
        finish.onFinish = { [weak self] in self?.stop() }
    }

    func toggle(_ id: UUID, url: URL) {
        if playing == id {
            stop()
            return
        }
        stop()
        // Not while recording: switching the session to playback cuts a recording off.
        guard !AudioRecorder.isRecordingAnywhere else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        guard let next = try? AVAudioPlayer(contentsOf: url) else { return }
        next.delegate = finish
        next.play()
        player = next
        playing = id
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
    }
}

/// The delegate callback arrives off the main actor; this hops it back on.
private final class FinishRelay: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    @MainActor var onFinish: (() -> Void)?

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.onFinish?() }
    }
}
