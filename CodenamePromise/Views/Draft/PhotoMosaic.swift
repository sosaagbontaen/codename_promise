import CodenamePromiseCore
import SwiftUI

/// Up to four photos in a grid, the last one counting whatever else there is.
///
/// One fills the space; two sit side by side; three put one tall on the left beside two
/// stacked; four make a square. The count rides on the last tile rather than beside it.
struct PhotoMosaic: View {
    let thumbs: [DraftSummary.Thumb]
    let overflow: Int
    let fileStore: MediaFileStore
    private let gap: CGFloat = 2

    var body: some View {
        let shown = Array(thumbs.prefix(4))
        switch shown.count {
        case 1:
            tile(shown, 0)
        case 2:
            HStack(spacing: gap) { tile(shown, 0); tile(shown, 1) }
        case 3:
            HStack(spacing: gap) {
                tile(shown, 0)
                VStack(spacing: gap) { tile(shown, 1); tile(shown, 2) }
            }
        default:
            VStack(spacing: gap) {
                HStack(spacing: gap) { tile(shown, 0); tile(shown, 1) }
                HStack(spacing: gap) { tile(shown, 2); tile(shown, 3) }
            }
        }
    }

    @ViewBuilder
    private func tile(_ shown: [DraftSummary.Thumb], _ index: Int) -> some View {
        let isLast = index == shown.count - 1
        PhotoTile(thumb: shown[index], fileStore: fileStore)
            .overlay {
                if isLast, overflow > 0 {
                    Rectangle().fill(.black.opacity(0.5))
                    Text("+\(overflow)")
                        .font(Type.label(17, .bold))
                        .foregroundStyle(.white)
                }
            }
    }
}

/// A photo cropped to whatever space it's given.
///
/// The image is an overlay on a flexible colour rather than a sibling in a stack, so a
/// landscape photo can't widen the card it sits in, which the old list learned the hard way.
struct PhotoTile: View {
    let thumb: DraftSummary.Thumb
    let fileStore: MediaFileStore
    /// Largest edge to decode, in pixels. Defaults to card size.
    var maxPixel: CGFloat = 420
    @State private var image: UIImage?

    var body: some View {
        Brand.ground
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if thumb.isVideo {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 3)
                        .padding(7)
                }
            }
            .task(id: thumb.id) {
                if image == nil {
                    image = await ThumbnailCache.shared.thumbnail(
                        id: thumb.id, relativePath: thumb.relativePath,
                        isVideo: thumb.isVideo, fileStore: fileStore, maxPixel: maxPixel
                    )
                }
            }
    }
}
