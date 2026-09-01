import CodenamePromiseCore
import SwiftUI

/// The photos from a day, as one picture rather than a row of stamps.
///
/// A strip of small thumbnails says "this record has four attachments". A collage says "that
/// night" — which is the reaction the list exists to produce. Same data, and the difference
/// is entirely in how much room it is given.
///
/// The layout adapts to how many there are, because four cells with two of them empty looks
/// like a bug, and one photo stretched across a 2x2 grid looks like a mistake.
struct MediaCollage: View {
    let thumbs: [DraftSummary.Thumb]
    let overflow: Int
    let fileStore: MediaFileStore

    private let gap: CGFloat = 3
    private let corner: CGFloat = 14

    var body: some View {
        Group {
            switch thumbs.count {
            case 0:
                EmptyView()
            case 1:
                // One photo gets a wide frame: it is the memory, not a thumbnail of it.
                // .fit, not .fill: fill lets the cell exceed the ratio, and one photo was
                // eating most of the screen.
                cell(thumbs[0]).aspectRatio(16/10, contentMode: .fit)
            case 2:
                HStack(spacing: gap) {
                    cell(thumbs[0]); cell(thumbs[1])
                }
                .aspectRatio(16/9, contentMode: .fit)
            case 3:
                HStack(spacing: gap) {
                    cell(thumbs[0])
                    VStack(spacing: gap) { cell(thumbs[1]); cell(thumbs[2]) }
                        .frame(maxWidth: .infinity)
                }
                .aspectRatio(16/10, contentMode: .fit)
            default:
                VStack(spacing: gap) {
                    HStack(spacing: gap) { cell(thumbs[0]); cell(thumbs[1]) }
                    HStack(spacing: gap) {
                        cell(thumbs[2])
                        if overflow > 0 { overflowCell } else { cell(thumbs[3]) }
                    }
                }
                .aspectRatio(1.15, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner))
    }

    private func cell(_ thumb: DraftSummary.Thumb) -> some View {
        CollageTile(thumb: thumb, fileStore: fileStore)
    }

    /// The last cell counts what is not shown, rather than a chip floating beside the strip.
    private var overflowCell: some View {
        ZStack {
            CollageTile(thumb: thumbs[3], fileStore: fileStore)
            Rectangle().fill(.black.opacity(0.55))
            Text("+\(overflow)")
                .font(Type.display(21, .semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

private struct CollageTile: View {
    let thumb: DraftSummary.Thumb
    let fileStore: MediaFileStore

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Brand.surface
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .task {
            if image == nil {
                // Bigger than the old 140: these are display sizes now, not stamps.
                image = await ThumbnailCache.shared.thumbnail(
                    id: thumb.id, relativePath: thumb.relativePath,
                    isVideo: thumb.isVideo, fileStore: fileStore, maxPixel: 420
                )
            }
        }
    }
}
