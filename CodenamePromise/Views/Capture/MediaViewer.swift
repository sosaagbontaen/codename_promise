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

    var body: some View {
        Group {
            switch item.kind {
            case .video:
                VideoPlayer(player: AVPlayer(url: fileStore.url(for: item.relativePath)))
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

    private func load() async {
        // A larger thumbnail rather than the full original: at sheet size the difference is
        // invisible, and decoding a 12-megapixel photo to fill a phone-width sheet is a lot
        // of memory for nothing.
        image = await ThumbnailCache.shared.thumbnail(
            for: item, fileStore: fileStore, maxPixel: 1400
        )
    }
}
