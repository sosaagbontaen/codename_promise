import Foundation

/// How to make a video fit a destination that caps individual files.
///
/// Notion's free plan allows 5 MiB per file, which a phone video is one to two orders of
/// magnitude over. The old answer was to re-encode the whole clip down to one 4.5 MiB file
/// and, when that couldn't be done, to give up: the video was dropped and the entry synced
/// without it. That is a bad trade twice over. A four-minute clip was refused entirely, and a
/// two-minute one was crushed to a bitrate that made it unwatchable, when the cap is on each
/// *file* and nothing stops an entry holding several.
///
/// So the cap is treated as a budget per part rather than a budget per video. Splitting buys
/// back quality: bits available is `parts x budget`, so a clip that needed 300 kbps as one
/// file gets 1.2 Mbps as four. The plan picks the fewest parts that keeps the picture above a
/// floor, then spends the whole budget of those parts on quality.
///
/// This is arithmetic, so it lives here and is tested here. Everything AVFoundation-shaped
/// stays in the app.
public enum VideoPlan: Sendable, Equatable {
    /// Already under the cap. Re-encoding would only lose quality.
    case asIs

    /// One file, encoded to these settings.
    case single(VideoEncoding)

    /// Several files, each covering one stretch of the clip.
    case split(segments: [VideoSegment], encoding: VideoEncoding)

    /// Long enough that even the quality floor would need more parts than anyone wants on a
    /// page. Nothing is deleted; the video stays on the device. See `Limits.maxParts`.
    case tooLong(seconds: Double, wouldNeedParts: Int)
}

public struct VideoEncoding: Sendable, Equatable {
    public let videoBitrate: Int
    public let audioBitrate: Int
    /// Longest edge in pixels. The short edge follows from the source's aspect ratio.
    public let longestSide: Int
    public let frameRate: Int

    public init(videoBitrate: Int, audioBitrate: Int, longestSide: Int, frameRate: Int) {
        self.videoBitrate = videoBitrate
        self.audioBitrate = audioBitrate
        self.longestSide = longestSide
        self.frameRate = frameRate
    }
}

/// One stretch of the original, in seconds from its start.
public struct VideoSegment: Sendable, Equatable {
    public let index: Int
    public let start: Double
    public let duration: Double

    public init(index: Int, start: Double, duration: Double) {
        self.index = index
        self.start = start
        self.duration = duration
    }
}

public enum VideoPlanner {

    public struct Limits: Sendable, Equatable {
        /// The destination's per-file cap, minus headroom. Encoders target an *average*
        /// bitrate and overshoot it on high-motion footage, and finding that out by being
        /// rejected after a two-minute export is a bad way to find it out.
        public var bytesPerFile: Int

        /// Low and mono. Speech survives it, and every bit here is a bit the picture doesn't
        /// get. On a journal clip the words are usually the point.
        public var audioBitrate: Int

        /// Container overhead and bitrate overshoot, as a fraction kept back.
        public var headroom: Double

        /// How many files one video may become.
        ///
        /// Twelve is a judgement, not a law: at the floor that covers about eighteen minutes,
        /// which is past any clip a journal entry has wanted so far, and twelve video blocks
        /// is already a lot to scroll past. Beyond it the honest answer is that the video
        /// stays on the phone.
        public var maxParts: Int

        public init(
            bytesPerFile: Int = 4_718_592,  // 4.5 MiB, under Notion's free-plan 5 MiB
            audioBitrate: Int = 48_000,
            headroom: Double = 0.95,
            maxParts: Int = 12
        ) {
            self.bytesPerFile = bytesPerFile
            self.audioBitrate = audioBitrate
            self.headroom = headroom
            self.maxParts = maxParts
        }

        public var usableBitsPerFile: Double {
            Double(bytesPerFile) * 8 * headroom
        }
    }

    /// The lowest bitrate worth encoding at.
    ///
    /// Below roughly this, no codec produces something worth keeping — information theory
    /// rather than a lack of cleverness. It is where the planner stops trying, and it is the
    /// quality the user agreed to sacrifice down to, not a target to aim for.
    public static let floorBitrate = 350_000

    /// Decides how to fit `durationSeconds` of video into files of `limits.bytesPerFile`.
    ///
    /// The rule is the fewest parts that keeps the picture at or above the floor. Fewest
    /// parts first, because a page with three video blocks is something you can watch and a
    /// page with eleven is something you scroll past; quality is what gets spent to stay
    /// whole, which is the trade the cap actually forces.
    ///
    /// - Parameter originalBytes: what the file weighs now, so a video already under the cap
    ///   is left alone.
    /// - Parameter sourceBitrate: the source's own video bitrate, when known. Encoding above
    ///   it invents nothing and only makes the file bigger, so it caps the result — and a
    ///   source that is *already* below the floor is encoded at its own bitrate rather than
    ///   refused, since re-encoding cannot be what made it bad.
    public static func plan(
        durationSeconds: Double,
        originalBytes: Int,
        sourceBitrate: Int? = nil,
        limits: Limits = Limits()
    ) -> VideoPlan {
        guard durationSeconds > 0 else { return .asIs }
        if originalBytes <= limits.bytesPerFile { return .asIs }

        let ceiling = (sourceBitrate ?? 0) > 0 ? sourceBitrate! : Int.max
        let acceptable = min(floorBitrate, ceiling)

        for parts in 1...max(1, limits.maxParts) {
            let secondsEach = durationSeconds / Double(parts)
            let available = limits.usableBitsPerFile / secondsEach - Double(limits.audioBitrate)
            guard available >= Double(acceptable) else { continue }
            return assemble(
                parts: parts,
                durationSeconds: durationSeconds,
                available: available,
                ceiling: ceiling,
                limits: limits
            )
        }

        let floorSeconds = limits.usableBitsPerFile / Double(floorBitrate + limits.audioBitrate)
        return .tooLong(
            seconds: durationSeconds,
            wouldNeedParts: max(1, Int(ceil(durationSeconds / floorSeconds)))
        )
    }

    /// Spends the whole budget of the parts we settled on.
    ///
    /// Having chosen a part count, the bitrate is whatever those parts can hold rather than
    /// some nominal rung — a twenty-second clip that fits in one part gets the entire budget,
    /// not a preset's idea of "medium". The parts are divided evenly too, so nothing ends on
    /// a three-second fragment.
    private static func assemble(
        parts: Int,
        durationSeconds: Double,
        available: Double,
        ceiling: Int,
        limits: Limits
    ) -> VideoPlan {
        let bitrate = min(Int(available), ceiling)
        let encoding = VideoEncoding(
            videoBitrate: bitrate,
            audioBitrate: limits.audioBitrate,
            longestSide: longestSide(for: bitrate),
            frameRate: bitrate < 400_000 ? 24 : 30
        )

        guard parts > 1 else { return .single(encoding) }
        return .split(segments: segments(count: parts, over: durationSeconds), encoding: encoding)
    }

    /// Divides a clip into evenly sized pieces.
    public static func segments(count: Int, over durationSeconds: Double) -> [VideoSegment] {
        let secondsEach = durationSeconds / Double(max(count, 1))
        return (0..<max(count, 1)).map { index in
            VideoSegment(
                index: index,
                start: Double(index) * secondsEach,
                // The last one runs to the end rather than to a computed boundary, so
                // rounding can't clip the final frames off.
                duration: index == count - 1
                    ? durationSeconds - Double(index) * secondsEach
                    : secondsEach
            )
        }
    }

    /// The best bitrate `count` parts of a clip can hold, never above what the source had.
    public static func bitrate(
        forParts count: Int, over durationSeconds: Double, sourceBitrate: Int,
        limits: Limits = Limits()
    ) -> Int {
        let secondsEach = durationSeconds / Double(max(count, 1))
        let available = limits.usableBitsPerFile / secondsEach - Double(limits.audioBitrate)
        let ceiling = sourceBitrate > 0 ? sourceBitrate : Int.max
        return max(min(Int(available), ceiling), 1)
    }

    /// The resolution that suits a bitrate.
    public static func longestSide(for bitrate: Int) -> Int {
        switch bitrate {
        case 2_500_000...: 1920
        case 1_200_000...: 1280
        case 600_000...: 960
        case 300_000...: 640
        default: 480
        }
    }
}
