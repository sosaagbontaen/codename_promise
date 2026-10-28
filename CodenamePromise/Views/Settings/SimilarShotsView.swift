import CodenamePromiseCore
import Photos
import SwiftUI

/// The runs of similar shots a fill found, for choosing which frames come in. Kept ones are
/// ticked; tap a photo to switch it. Nothing here is deleted from the library, and frames
/// left out are remembered so a later fill doesn't ask about them again.
struct SimilarShotsView: View {
    let filler: PhotoBackfillCoordinator

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 4)]

    var body: some View {
        List {
            ForEach(filler.groups) { group in
                Section {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(group.assets, id: \.id) { asset in
                            let kept = group.keep.contains(asset.id)
                            Button {
                                filler.setKeep(asset.id, !kept, in: group.id)
                                Haptics.picked()
                            } label: {
                                LibraryThumbnail(id: asset.id)
                                    .aspectRatio(1, contentMode: .fill)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .opacity(kept ? 1 : 0.45)
                                    .overlay(alignment: .topTrailing) {
                                        Image(systemName: kept ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 20))
                                            .foregroundStyle(kept ? Brand.violet : .white)
                                            .background(Circle().fill(.black.opacity(0.25)))
                                            .padding(5)
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(kept ? "Kept" : "Left out")
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    HStack {
                        Text(header(group))
                        Spacer()
                        Button("Keep all") { filler.keepAll(in: group.id) }
                            .font(.footnote.weight(.semibold))
                            .textCase(nil)
                    }
                }
            }
        }
        .navigationTitle("Similar shots")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func header(_ group: PhotoBackfillCoordinator.SimilarGroup) -> String {
        let day = group.day.representativeDate().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
        return "\(day) \u{00B7} \(group.keep.count) of \(group.assets.count) kept"
    }
}

/// A photo from the library, drawn small. Uses the library's own thumbnail, so it's quick
/// even when the original is only in iCloud.
struct LibraryThumbnail: View {
    let id: String
    @State private var image: UIImage?

    var body: some View {
        Color.secondary.opacity(0.15)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .clipped()
            .task(id: id) {
                guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return }
                let options = PHImageRequestOptions()
                options.deliveryMode = .opportunistic
                options.isNetworkAccessAllowed = true
                image = await withCheckedContinuation { continuation in
                    var resumed = false
                    PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 300, height: 300),
                                                          contentMode: .aspectFill, options: options) { result, info in
                        // Opportunistic delivery calls twice, a quick low-quality image then
                        // the real one; only the final call counts.
                        let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                        guard !degraded, !resumed else { return }
                        resumed = true
                        continuation.resume(returning: result)
                    }
                }
            }
    }
}
