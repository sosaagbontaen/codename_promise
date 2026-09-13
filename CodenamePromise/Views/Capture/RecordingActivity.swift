#if canImport(ActivityKit)
import ActivityKit
#endif
import Foundation
import OSLog

private let log = Logger(subsystem: "com.codenamepromise.journal", category: "activity")

/// The recording timer on the Lock Screen and in the Dynamic Island.
///
/// Recording now continues after you leave the app, and the only thing that said so was the
/// microphone dot in the status bar — which tells you something is listening, not what, for
/// how long, or whether you paused it. This is the part you can read.
///
/// Every call is best effort. A Live Activity can be refused for reasons that have nothing to
/// do with this app: the user turned them off, the system is out of slots, the device is old.
/// None of that is allowed to affect the recording, so nothing here throws and nothing here
/// is awaited by the recorder.
@MainActor
enum RecordingActivity {

    #if canImport(ActivityKit)
    private static var current: Activity<RecordingActivityAttributes>?

    /// `Activity` is a plain class whose `update` and `end` are `nonisolated async`, so Swift
    /// 6 reads every call from the main actor as sending a non-Sendable value across an
    /// isolation boundary. The framework is safe to use this way — it is how Apple's own
    /// sample code drives it — and this states that promise once, here, rather than leaving
    /// a suppression at each call site.
    private struct Handle: @unchecked Sendable {
        let activity: Activity<RecordingActivityAttributes>
    }
    #endif

    /// Clears anything left over from a process that is no longer running.
    ///
    /// A Live Activity outlives the app that started it — that is the point of it, and it is
    /// also how force-quitting mid-recording left a timer sitting in the Dynamic Island
    /// afterwards, frozen at whatever it last said, with nothing behind it. A recording never
    /// survives the process, so any activity found at launch is by definition stale.
    ///
    /// Also runs before starting a new one, because `current` is nil in a fresh process and
    /// the leftover would otherwise sit there while a second activity was requested behind
    /// it.
    static func endStale() {
        #if canImport(ActivityKit)
        for activity in Activity<RecordingActivityAttributes>.activities {
            let handle = Handle(activity: activity)
            Task { await handle.activity.end(nil, dismissalPolicy: .immediate) }
        }
        current = nil
        #endif
    }

    static func start(entryName: String) {
        #if canImport(ActivityKit)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        endStale()

        let state = RecordingActivityAttributes.ContentState(
            runningSince: Date(), bankedSeconds: 0, isRecording: true
        )
        do {
            current = try Activity.request(
                attributes: RecordingActivityAttributes(entryName: entryName),
                content: .init(state: state, staleDate: nil)
            )
        } catch {
            // Genuinely fine. The recording is unaffected; only the Lock Screen misses out.
            log.info("live activity refused: \(error.localizedDescription)")
        }
        #endif
    }

    /// Moves the timer between counting and frozen.
    ///
    /// `banked` is everything recorded so far. While running, the widget counts up from
    /// `now - banked` on its own rather than being pushed a number every second: activity
    /// updates are rate limited and cost power, and a system-animated timer never drifts.
    static func update(banked: TimeInterval, isRecording: Bool) {
        #if canImport(ActivityKit)
        guard let current else { return }
        let state = RecordingActivityAttributes.ContentState(
            runningSince: isRecording ? Date() : nil,
            bankedSeconds: banked,
            isRecording: isRecording
        )
        let handle = Handle(activity: current)
        Task { await handle.activity.update(.init(state: state, staleDate: nil)) }
        #endif
    }

    static func end() {
        #if canImport(ActivityKit)
        guard let activity = current else { return }
        current = nil
        // Dismissed immediately rather than left on the Lock Screen: the recording is over,
        // and an activity that lingers is something the person has to go and clear.
        let handle = Handle(activity: activity)
        Task { await handle.activity.end(nil, dismissalPolicy: .immediate) }
        #endif
    }
}
