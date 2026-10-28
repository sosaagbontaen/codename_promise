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
/// phone video is one to two orders of magnitude over budget.
///
/// The cap is per *file*, though, and an entry can hold several. A clip too long to fit one
/// file is cut into parts that each fit, rather than abandoned — which is what used to happen
/// past about three and a half minutes: re-encoded, measured, found still too big, and
/// dropped. `VideoPlanner` in Core decides how many parts and at what bitrate; this runs the
/// encoder. Past roughly eighteen minutes even the maximum number of parts would be below
/// the quality floor, and there the honest answer is that the video stays on the phone
/// (`tooLargeToSend`), which is still a complete entry (ADR-015a).
///
/// The original is never replaced. Compression writes a *derivative* and records it in
/// `compressedRelativePath`; `pathForUpload` prefers it. What the user attached stays exactly
/// as it was on their device (invariant 5).
@MainActor
struct MediaCompressor {
    let fileStore: MediaFileStore
    let store: DraftStore

    /// The destination's per-file cap, and how far a video may be split to meet it.
    var limits = VideoPlanner.Limits()

    private var targetBytes: Int { limits.bytesPerFile }

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
        switch item.kind {
        case .video:
            await compressVideo(item, at: source, originalSize: originalSize)
        case .photo:
            let target = targetBytes
            let data = await Task.detached(priority: .utility) { Self.compressPhoto(at: source, targetBytes: target) }.value
            keep(data, on: item, extension: "jpg")
        }
    }

    /// Writes one derivative and records it, or records that there wasn't one.
    private func keep(_ data: Data?, on item: MediaItem, extension ext: String) {
        guard let data else {
            // Couldn't shrink it. Not a failure of the entry — the words still sync.
            item.compressionStatus = .failed
            try? store.flush()
            return
        }
        do {
            let written = try fileStore.write(
                data, id: item.id, preferredName: "compressed", extension: ext
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

    /// Asks the planner what shape this video has to take, then encodes it.
    private func compressVideo(_ item: MediaItem, at url: URL, originalSize: Int) async {
        guard let info = await VideoTranscoder.inspect(source: url) else {
            item.compressionStatus = .failed
            try? store.flush()
            return
        }

        let plan = VideoPlanner.plan(
            durationSeconds: info.seconds,
            originalBytes: originalSize,
            sourceBitrate: info.bitrate,
            limits: limits
        )
        log.info("plan for \(Int(info.seconds))s / \(originalSize) bytes: \(String(describing: plan))")

        switch plan {
        case .asIs:
            item.markCompressionSkipped()
            try? store.flush()

        case .single(let encoding):
            guard let output = await VideoTranscoder.transcode(source: url, encoding: encoding),
                  let data = try? Data(contentsOf: output)
            else {
                item.compressionStatus = .failed
                try? store.flush()
                return
            }
            try? FileManager.default.removeItem(at: output)
            // The encoder targets an *average* bitrate, so high-motion footage can overshoot.
            // An overshoot is not a reason to throw the encode away any more: splitting it is
            // the better answer, and one part over by a few percent still beats nothing.
            log.info("transcoded to \(data.count) bytes (cap \(targetBytes))")
            if data.count <= targetBytes {
                keep(data, on: item, extension: "mp4")
            } else {
                await splitVideo(item, at: url, seconds: info.seconds, bitrate: info.bitrate)
            }

        case .split(let segments, let encoding):
            await encodeParts(item, at: url, segments: segments, encoding: encoding)

        case .tooLong(let seconds, let wouldNeed):
            // Nothing is deleted. The video is in the entry and on the phone; it just does
            // not travel, and the app says so instead of failing quietly.
            log.info("too long to send: \(Int(seconds))s would need \(wouldNeed) parts")
            item.markTooLargeToSend()
            try? store.flush()
        }
    }

    /// Cuts a clip in two after a single-file encode overshot the cap.
    ///
    /// Reached when the encoder missed its average bitrate badly enough to land over budget —
    /// high-motion footage does this. Rather than give up, which is what used to happen, each
    /// half gets the whole budget to itself: a wide margin on the same footage.
    ///
    /// Deliberately does not ask the planner again. The planner answers "what shape does this
    /// clip need", and it already answered "one file" — asking a second time with a tighter
    /// cap gave back `.single` for anything short, and the guard on that turned an overshoot
    /// into an abandoned video. The question here is different and simpler: split what the
    /// planner thought would fit.
    private func splitVideo(
        _ item: MediaItem, at url: URL, seconds: Double, bitrate: Int
    ) async {
        let parts = 2
        let encoding = VideoEncoding(
            videoBitrate: VideoPlanner.bitrate(
                forParts: parts, over: seconds, sourceBitrate: bitrate, limits: limits
            ),
            audioBitrate: limits.audioBitrate,
            longestSide: VideoPlanner.longestSide(
                for: VideoPlanner.bitrate(
                    forParts: parts, over: seconds, sourceBitrate: bitrate, limits: limits
                )
            ),
            frameRate: 30
        )
        await encodeParts(
            item, at: url,
            segments: VideoPlanner.segments(count: parts, over: seconds),
            encoding: encoding
        )
    }

    /// Encodes each segment to its own file and records them on the item, in order.
    ///
    /// All or nothing: a video represented by three of its four minutes, with nothing saying
    /// the fourth is missing, is worse than one that plainly did not make it.
    private func encodeParts(
        _ item: MediaItem, at url: URL, segments: [VideoSegment], encoding: VideoEncoding
    ) async {
        var written: [String] = []
        var total = 0

        for segment in segments {
            let range = CMTimeRange(
                start: CMTime(seconds: segment.start, preferredTimescale: 600),
                duration: CMTime(seconds: segment.duration, preferredTimescale: 600)
            )
            guard
                let output = await VideoTranscoder.transcode(
                    source: url, encoding: encoding, timeRange: range
                ),
                let data = try? Data(contentsOf: output),
                let file = try? fileStore.write(
                    data, id: item.id,
                    preferredName: "part-\(segment.index)", extension: "mp4"
                )
            else {
                log.error("part \(segment.index) of \(segments.count) failed to encode")
                // Clean up the parts that did encode rather than leave them orphaned.
                fileStore.delete(relativePaths: written)
                item.compressionStatus = .failed
                try? store.flush()
                return
            }
            try? FileManager.default.removeItem(at: output)
            written.append(file.relativePath)
            total += file.sizeBytes
        }

        log.info("split into \(written.count) parts, \(total) bytes total")
        item.markSplit(into: written, totalBytes: total, level: .medium)
        try? store.flush()
    }

    // MARK: - Photo

    /// Steps the JPEG quality down until it fits, downscaling first if the image is huge.
    ///
    /// Off the main actor, and through ImageIO: it reads only as much of the original as a
    /// 2048-pixel image needs. The UIKit version decoded the whole photo on the main thread
    /// and, because its renderer used the screen's scale, drew it three times the intended
    /// size, which froze the screen for seconds per photo.
    nonisolated private static func compressPhoto(at url: URL, targetBytes: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        func jpeg(_ quality: Double) -> Data? {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            return CGImageDestinationFinalize(destination) ? data as Data : nil
        }
        for quality in stride(from: 0.8, through: 0.3, by: -0.1) {
            if let data = jpeg(quality), data.count <= targetBytes { return data }
        }
        return jpeg(0.3)
    }
}
