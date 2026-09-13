#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// What the Lock Screen and Dynamic Island are told about a recording in progress.
///
/// Shared by the app, which starts and updates the activity, and the widget extension, which
/// draws it. It is deliberately tiny: a Live Activity's state crosses a process boundary on
/// every update, and anything in here is something the system keeps a copy of. The entry's
/// words are never part of it.
struct RecordingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// When the run of recording currently on screen began, so the widget can run its own
        /// clock with `Text(timerInterval:)` instead of being woken every second.
        ///
        /// Live Activity updates are rate limited and cost power; a timer the system animates
        /// itself costs nothing and never drifts. This moves on resume, which is why the
        /// paused total is carried separately.
        public var runningSince: Date?

        /// Seconds already recorded before the current run — everything banked by earlier
        /// chunks. The whole elapsed time is this plus however long `runningSince` has been
        /// going.
        public var bankedSeconds: TimeInterval

        /// False while paused, which is the only thing the widget renders differently.
        public var isRecording: Bool

        public init(runningSince: Date?, bankedSeconds: TimeInterval, isRecording: Bool) {
            self.runningSince = runningSince
            self.bankedSeconds = bankedSeconds
            self.isRecording = isRecording
        }

        /// The instant a timer showing total elapsed time should count up from.
        ///
        /// `Text(timerInterval:)` counts from a date, so the banked time is expressed by
        /// moving the start date backwards rather than by adding a number to it.
        public var countingFrom: Date {
            (runningSince ?? Date()).addingTimeInterval(-bankedSeconds)
        }
    }

    /// Which entry is being recorded into, so the Lock Screen names it rather than saying
    /// "Recording" over and over.
    public var entryName: String

    public init(entryName: String) {
        self.entryName = entryName
    }
}
#endif
