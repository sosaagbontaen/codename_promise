import AVFoundation
import CodenamePromiseCore
import Foundation
import ImageIO
import UIKit
import OSLog
import UniformTypeIdentifiers

private let log = Logger(subsystem: "com.codenamepromise.journal", category: "compress")

/// Shrinks attached media so it fits the destination's file-size limit.
///
/// This is ADR-015 — compress on the device, not on the server. Uploading an 80MB video in
/// order to be told it's too big wastes the user's bandwidth and ships their private journal
/// media somewhere it doesn't need to go.
///
/// Notion caps individual files by workspace plan, and on the free plan that is 5 MiB, so a
/// phone video is one to two orders of magnitude over budget. Compression makes short clips
/// fit; it will not make a five-minute video fit, and this deliberately does not pretend
/// otherwise — it reports honestly and lets the entry sync without the file (ADR-015a).
///
/// The original is never replaced. Compression writes a *derivative* and records it in
/// `compressedRelativePath`; `pathForUpload` prefers it. What the user attached stays exactly
/// as it was on their device (invariant 5).
@MainActor
struct MediaCompressor {
    let fileStore: MediaFileStore
    let store: DraftStore

    /// A little under the real ceiling: encoders overshoot their target bitrate, and being
    /// rejected after a two-minute export is a bad way to find that out.
    var targetBytes: Int = Int(4.5 * 1024 * 1024)

    func compressIfNeeded(_ item: MediaItem) async {
        guard item.compressionStatus == .pending else { return }
        let sourcePath = item.relativePath
        guard fileStore.exists(sourcePath) else { return }

        let originalSize = fileStore.sizeBytes(of: sourcePath) ?? item.originalSizeBytes
        guard originalSize > targetBytes else {
            item.markCompressionSkipped()
            try? store.flush()
            return
        }

        item.compressionStatus = .compressing
        try? store.flush()

        let source = fileStore.url(for: sourcePath)
        let result: Data?
        switch item.kind {
        case .video:
            result = await compressVideo(at: source)
        case .photo:
            result = compressPhoto(at: source)
        }

        log.info("compress: \(item.kind.rawValue) \(originalSize) bytes -> \(result?.count ?? -1)")
        guard let data = result else {
            // Couldn't shrink it. Not a failure of the entry — the words still sync.
            item.compressionStatus = .failed
            try? store.flush()
            return
        }

        do {
            let written = try fileStore.write(
                data,
                id: item.id,
                preferredName: "compressed",
                extension: item.kind == .video ? "mp4" : "jpg"
            )
            item.markCompressed(
                relativePath: written.relativePath,
                sizeBytes: written.sizeBytes,
                level: .medium
            )
            try store.flush()
        } catch {
            item.compressionStatus = .failed
            try? store.flush()
        }
    }

    // MARK: - Video

    /// Encodes to a bitrate derived from the budget and the clip's duration, rather than to
    /// a fixed-quality preset that has no idea how long the video is. See `VideoTranscoder`.
    private func compressVideo(at url: URL) async -> Data? {
        guard let output = await VideoTranscoder.transcode(
            source: url, budget: .init(bytes: targetBytes)
        ) else { return nil }
        defer { try? FileManager.default.removeItem(at: output) }

        guard let data = try? Data(contentsOf: output) else { return nil }
        // The encoder targets an *average* bitrate, so noisy or high-motion footage can still
        // overshoot. Logged because "returned nil" otherwise can't be told apart from a
        // transcode that never ran.
        log.info("transcoded to \(data.count) bytes (budget \(targetBytes))")
        return data.count <= targetBytes ? data : nil
    }

    // MARK: - Photo

    /// Steps the JPEG quality down until it fits, downscaling first if the image is huge.
    private func compressPhoto(at url: URL) -> Data? {
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }

        let maxDimension: CGFloat = 2048
        let scaled: UIImage
        if max(image.size.width, image.size.height) > maxDimension {
            let ratio = maxDimension / max(image.size.width, image.size.height)
            let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
            let renderer = UIGraphicsImageRenderer(size: size)
            scaled = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        } else {
            scaled = image
        }

        for quality in stride(from: 0.8, through: 0.3, by: -0.1) {
            if let data = scaled.jpegData(compressionQuality: quality), data.count <= targetBytes {
                return data
            }
        }
        return scaled.jpegData(compressionQuality: 0.3)
    }
}
