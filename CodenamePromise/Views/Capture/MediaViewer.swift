import AVKit
import CodenamePromiseCore
import SwiftUI

/// Full-size media, swipeable, presented so the editor stays usable underneath.
///
/// This exists because of how the entry actually gets written: attach the day's photos first,
/// then look through them and let them remind you what happened. Thumbnails are too small to
/// jog a memory, but a viewer that takes over the screen is worse — you'd be closing and
/// reopening it after every sentence.
///
/// So it's a sheet at the medium detent with background interaction enabled: the photo is
/// large, the editor is still right there, and typing doesn't dismiss it. Drag it up for a
/// proper look, drag it down and keep writing.
struct MediaViewer: View {
    let items: [MediaItem]
    let fileStore: MediaFileStore
    @State var selection: UUID

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TabView(selection: $selection) {
                ForEach(items, id: \.id) { item in
                    MediaPage(item: item, fileStore: fileStore)
                        .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: items.count > 1 ? .automatic : .never))
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(positionLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var positionLabel: String {
        guard items.count > 1,
              let index = items.firstIndex(where: { $0.id == selection })
        else { return "" }
        return "\(index + 1) of \(items.count)"
    }
}

private struct MediaPage: View {
    let item: MediaItem
    let fileStore: MediaFileStore

    @State private var image: UIImage?
    /// Built in `init`, and both halves of that matter.
    ///
    /// It was `VideoPlayer(player: AVPlayer(url:))` written inline in `body`, which builds a
    /// **new player on every body pass** - and inside a paging `TabView`, body runs constantly.
    /// Moving it to `@State` and filling it in from `.task` was still not enough: `VideoPlayer`
    /// wraps an `AVPlayerViewController` that takes its player when the representable is first
    /// made and does not reliably swap it afterwards, so handing it `nil` on the first render
    /// left it permanently empty.
    ///
    /// Either way the symptom was the same and gave no clue: a still first frame, no play
    /// button, no scrubber, nothing to tap. It read as an unsupported format. It was a player
    /// being thrown away, or one that arrived a frame too late.
    @State private var player: AVPlayer?
    private let fileMissing: Bool

    init(item: MediaItem, fileStore: MediaFileStore) {
        self.item = item
        self.fileStore = fileStore
        let missing = item.kind == .video && !fileStore.exists(item.relativePath)
        self.fileMissing = missing
        _player = State(initialValue: item.kind == .video && !missing
            ? AVPlayer(url: fileStore.url(for: item.relativePath))
            : nil)
    }

    var body: some View {
        Group {
            switch item.kind {
            case .video:
                if fileMissing {
                    // Says so, rather than showing a black rectangle. Container paths move on
                    // a restore-from-backup, so "the row is here and the bytes are not" is a
                    // state this app has to be able to describe (ADR-007).
                    ContentUnavailableView(
                        "Video unavailable", systemImage: "video.slash",
                        description: Text("The file couldn't be found on this device.")
                    )
                } else {
                    VideoPlayer(player: player)
                        .onAppear(perform: allowPlayback)
                        .onDisappear { player?.pause() }
                }
            case .photo:
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                        .task { await load() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Dictation leaves the audio session in `.record`, which silently refuses playback -
    /// and nothing about the resulting dead player says why.
    private func allowPlayback() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    private func load() async {
        // A larger thumbnail rather than the full original: at sheet size the difference is
        // invisible, and decoding a 12-megapixel photo to fill a phone-width sheet is a lot
        // of memory for nothing.
        image = await ThumbnailCache.shared.thumbnail(
            for: item, fileStore: fileStore, maxPixel: 1400
        )
    }
}
