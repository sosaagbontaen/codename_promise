#if canImport(ActivityKit)
import ActivityKit
import SwiftUI
import WidgetKit

/// The recording, on the Lock Screen and in the Dynamic Island.
///
/// The point of this is not decoration. Recording continues after you leave the app, and
/// without something on the Lock Screen the only evidence is the microphone dot in the status
/// bar — which tells you *something* is listening and not what, for how long, or whether you
/// paused it. This is the timer you can actually read.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            lockScreen(context.state, name: context.attributes.entryName)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.45))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.isRecording ? "mic.fill" : "pause.fill")
                        .font(.title3)
                        .foregroundStyle(context.state.isRecording ? .red : .secondary)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    elapsed(context.state)
                        .font(.title3.monospacedDigit())
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.isRecording
                         ? "Recording into \(context.attributes.entryName)"
                         : "Paused. Everything so far is saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: context.state.isRecording ? "mic.fill" : "pause.fill")
                    .foregroundStyle(context.state.isRecording ? .red : .secondary)
            } compactTrailing: {
                elapsed(context.state)
                    .font(.caption.monospacedDigit())
                    // Without a width the counter reflows the island every time the digits
                    // change width, which reads as a twitch.
                    .frame(width: 44)
            } minimal: {
                Image(systemName: context.state.isRecording ? "mic.fill" : "pause.fill")
                    .foregroundStyle(context.state.isRecording ? .red : .secondary)
            }
        }
    }

    private func lockScreen(
        _ state: RecordingActivityAttributes.ContentState, name: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: state.isRecording ? "mic.fill" : "pause.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(state.isRecording ? .red : .secondary)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(state.isRecording ? "Recording" : "Paused")
                    .font(.headline)
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            elapsed(state)
                .font(.title2.monospacedDigit())
        }
    }

    /// Counts up on its own rather than being pushed a new number every second.
    ///
    /// A paused activity shows a frozen total instead: `Text(timerInterval:)` has no way to
    /// stop, and a counter that keeps climbing while nothing is being recorded would be a lie
    /// told on the Lock Screen.
    @ViewBuilder
    private func elapsed(_ state: RecordingActivityAttributes.ContentState) -> some View {
        if state.isRecording {
            Text(timerInterval: state.countingFrom...Date.distantFuture, countsDown: false)
        } else {
            Text(Self.clock(state.bankedSeconds))
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

@main
struct DumpNotesWidgetBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
    }
}
#endif
