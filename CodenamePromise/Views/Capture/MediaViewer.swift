import AVKit
import CodenamePromiseCore
import SwiftUI

/// Full-size media on black: swipe sideways through the entry's photos and videos, pull
/// down or tap the X to close.
struct MediaViewer: View {
    let items: [MediaItem]
    let fileStore: MediaFileStore
    @State var selection: UUID

    @Environment(\.dismiss) private var dismiss
    /// How far the photo has been pulled down, to follow the finger before it closes.
    @State private var pull: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
                .opacity(1 - min(pull / 400, 0.6))

            TabView(selection: $selection) {
                ForEach(items, id: \.id) { item in
                    MediaPage(item: item, fileStore: fileStore)
                        .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: items.count > 1 ? .automatic : .never))
            .ignoresSafeArea()
            .offset(y: pull)
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        // Only a downward pull, so swiping sideways still pages.
                        if value.translation.height > abs(value.translation.width) {
                            pull = value.translation.height
                        }
                    }
                    .onEnded { value in
                        if value.translation.height > 120 {
                            dismiss()
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { pull = 0 }
                        }
                    }
            )

            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.white.opacity(0.15), in: Circle())
                }
                .accessibilityLabel("Close")
                Spacer()
                Text(positionLabel)
                    .font(Type.label(15, .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Color.clear.frame(width: 40, height: 40)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .opacity(pull > 0 ? 0 : 1)
        }
        .statusBarHidden()
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
