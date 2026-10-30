import AVKit
import CodenamePromiseCore
import SwiftUI

/// Full-size media on black, three ways: one at a time with a filmstrip, a grid of them all,
/// or all of them stacked full width to scroll down through. Pull down or tap X to close.
struct MediaViewer: View {
    let items: [MediaItem]
    let fileStore: MediaFileStore
    @State var selection: UUID

    @Environment(\.dismiss) private var dismiss

    enum Layout: String, CaseIterable {
        case single, grid, scroll
        var symbol: String {
            switch self {
            case .single: "rectangle"
            case .grid: "square.grid.3x3"
            case .scroll: "rectangle.grid.1x2"
            }
        }
        var label: String {
            switch self {
            case .single: "One at a time"
            case .grid: "Grid"
            case .scroll: "Scroll through"
            }
        }
    }

    @AppStorage("viewerLayout") private var layout: Layout = .single
    /// How far the photo has been pulled down, to follow the finger before it closes.
    @State private var pull: CGFloat = 0
    @State private var pullAxis: Axis?

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
                .opacity(1 - min(pull / 400, 0.6))

            Group {
                switch layout {
                case .single:
                    TabView(selection: $selection) {
                        ForEach(items, id: \.id) { item in
                            MediaPage(item: item, fileStore: fileStore)
                                .tag(item.id)
                        }
                    }
                    // The filmstrip below does what the page dots did, and more.
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .ignoresSafeArea()
                case .grid:
                    gridLayout
                case .scroll:
                    scrollLayout
                }
            }
            .offset(y: pull)
            // Alongside the pager's own swipe rather than in place of it. As a plain gesture it
            // could take over a swipe that drifted downward partway through, and the pager,
            // never told the finger had lifted, was left stuck between two photos.
            .simultaneousGesture(layout == .single ? pullToClose : nil)

            topBar

            if items.count > 1, layout == .single {
                VStack {
                    Spacer()
                    filmstrip
                }
                .opacity(pull > 0 ? 0 : 1)
            }
        }
        .statusBarHidden()
    }

    private var pullToClose: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                // Which way the drag is going is decided once, at its start: a sideways swipe
                // stays a swipe however it wanders, and only a downward one pulls to close.
                if pullAxis == nil {
                    pullAxis = value.translation.height > abs(value.translation.width) ? .vertical : .horizontal
                }
                if pullAxis == .vertical {
                    pull = max(value.translation.height, 0)
                }
            }
            .onEnded { value in
                let closing = pullAxis == .vertical && value.translation.height > 120
                pullAxis = nil
                if closing {
                    dismiss()
                } else if pull != 0 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { pull = 0 }
                }
            }
    }

    private var topBar: some View {
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
                Text(layout == .single ? positionLabel : "\(items.count) \(items.count == 1 ? "item" : "items")")
                    .font(Type.label(15, .semibold))
                    .foregroundStyle(.white)
                Spacer()
                HStack(spacing: 8) {
                    if layout == .single { shareButton }
                    if items.count > 1 { layoutSwitcher } else if layout != .single { Color.clear.frame(width: 40, height: 40) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .background {
                // Keeps the controls readable over a photo scrolling beneath them.
                if layout != .single {
                    LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea()
                }
            }
            .opacity(pull > 0 ? 0 : 1)
    }

    /// The share sheet for the photo or video on screen: save it, AirDrop it, send it.
    /// Shares the original as attached, not the smaller copy made for uploading.
    @ViewBuilder
    private var shareButton: some View {
        if let index = items.firstIndex(where: { $0.id == selection }) {
            let item = items[index]
            ShareLink(item: ShareableMedia.url(for: item, index: index, fileStore: fileStore)) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .accessibilityLabel(item.kind == .video ? "Share video" : "Share photo")
        }
    }

    private var layoutSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(Layout.allCases, id: \.self) { option in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { layout = option }
                } label: {
                    Image(systemName: option.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(layout == option ? .black : .white)
                        .frame(width: 34, height: 30)
                        .background { if layout == option { Capsule().fill(.white) } }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
            }
        }
        .padding(3)
        .background(.white.opacity(0.15), in: Capsule())
    }

    /// Every photo at once. Tap one to look at it on its own.
    private var gridLayout: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                    ForEach(items, id: \.id) { item in
                        Button {
                            selection = item.id
                            withAnimation(.easeInOut(duration: 0.2)) { layout = .single }
                        } label: {
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .overlay { FilmstripCell(item: item, fileStore: fileStore, maxPixel: 400) }
                                .clipped()
                                .overlay {
                                    if item.id == selection {
                                        Rectangle().strokeBorder(.white, lineWidth: 2)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                    }
                }
                .padding(.top, 64)
            }
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
        }
    }

    /// Every photo full width, one after another, to scroll down through like a feed.
    private var scrollLayout: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(items, id: \.id) { item in
                        FeedImage(item: item, fileStore: fileStore)
                            .id(item.id)
                            .onTapGesture {
                                selection = item.id
                                withAnimation(.easeInOut(duration: 0.2)) { layout = .single }
                            }
                    }
                }
                .padding(.top, 64)
                .padding(.bottom, 30)
            }
            .onAppear { proxy.scrollTo(selection, anchor: .top) }
        }
    }

    /// Every photo in the entry along the bottom, the current one lifted and outlined, the
    /// strip following as you swipe. Tap one to go straight to it.
    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 4) {
                    ForEach(items, id: \.id) { item in
                        let current = item.id == selection
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { selection = item.id }
                        } label: {
                            FilmstripCell(item: item, fileStore: fileStore)
                                .frame(width: current ? 44 : 34, height: 50)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay {
                                    if current {
                                        RoundedRectangle(cornerRadius: 4).strokeBorder(.white, lineWidth: 2)
                                    }
                                }
                                .opacity(current ? 1 : 0.6)
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 16)
                .animation(.easeOut(duration: 0.15), value: selection)
            }
            .frame(height: 50)
            .padding(.bottom, 24)
            .onChange(of: selection) { _, id in
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
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
    ///
    /// Made once, when the page first appears, and only then shown: the player used to be
    /// built in `init`, which runs on every redraw of the viewer (every frame of a pull to
    /// close), so each one made and threw away a player and checked the disk again.
    @State private var player: AVPlayer?
    @State private var fileMissing = false

    init(item: MediaItem, fileStore: MediaFileStore) {
        self.item = item
        self.fileStore = fileStore
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
                } else if let player {
                    VideoPlayer(player: player)
                        .onAppear(perform: allowPlayback)
                        .onDisappear { player.pause() }
                } else {
                    Color.black.task {
                        guard fileStore.exists(item.relativePath) else {
                            fileMissing = true
                            return
                        }
                        player = AVPlayer(url: fileStore.url(for: item.relativePath))
                    }
                }
            case .photo:
                if let image {
                    ZoomableImage(image: image)
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
        // Not while recording: switching the session to playback cuts the recording off,
        // silently. The video plays muted instead, and the recording is untouched.
        guard !AudioRecorder.isRecordingAnywhere else { return }
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

/// A small thumbnail in the viewer's filmstrip.
private struct FilmstripCell: View {
    let item: MediaItem
    let fileStore: MediaFileStore
    var maxPixel: CGFloat = 132
    @State private var image: UIImage?

    var body: some View {
        Color.white.opacity(0.1)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if item.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                }
            }
            .task(id: item.id) {
                image = await ThumbnailCache.shared.thumbnail(for: item, fileStore: fileStore, maxPixel: maxPixel)
            }
    }
}

/// A photo at full width and its own height, for the scrolling layout. Videos show their
/// first frame with a play mark; tapping opens them one at a time to play.
private struct FeedImage: View {
    let item: MediaItem
    let fileStore: MediaFileStore
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.white.opacity(0.06).aspectRatio(4 / 3, contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity)
        .overlay {
            if item.kind == .video {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .task(id: item.id) {
            image = await ThumbnailCache.shared.thumbnail(for: item, fileStore: fileStore, maxPixel: 1400)
        }
    }
}

/// A photo you can pinch to zoom, pan around while zoomed, and double-tap to zoom in or back
/// out, the way Photos works. A UIScrollView underneath, because it does this natively and
/// passes sideways swipes through to the pager whenever the photo isn't zoomed.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = FittingScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.bouncesZoom = true
        scroll.backgroundColor = .clear
        scroll.contentInsetAdjustmentBehavior = .never

        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.isUserInteractionEnabled = true
        scroll.addSubview(view)
        scroll.imageView = view
        context.coordinator.imageView = view

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        guard let view = context.coordinator.imageView else { return }
        if view.image !== image {
            view.image = image
            scroll.setNeedsLayout()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Fits the photo to the page whenever its size settles, at zoom 1. Done in layout
    /// rather than on update, because the page's size isn't known until layout, and before
    /// then the photo was drawn at its full pixel size, filling the screen with one corner.
    final class FittingScrollView: UIScrollView {
        weak var imageView: UIImageView?

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let imageView, zoomScale == 1, bounds.size != .zero else { return }
            if imageView.frame.size != bounds.size {
                imageView.frame = CGRect(origin: .zero, size: bounds.size)
                contentSize = bounds.size
            }
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @MainActor @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView, let imageView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                // Zoom in on the spot that was tapped.
                let point = gesture.location(in: imageView)
                let scale: CGFloat = 2.5
                let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
            }
        }
    }
}
