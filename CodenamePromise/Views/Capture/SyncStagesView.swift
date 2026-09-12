import CodenamePromiseCore
import SwiftUI

/// What is happening to this entry, as three things rather than one sentence.
///
/// A single line that kept being replaced — "Uploading photo 2 of 5…" — told somebody what
/// the app was busy with and not what they wanted to know, which is whether their writing
/// had arrived and what was holding the rest up. Three stages, each visibly waiting, working
/// or done, answers that at a glance and stays answered.
///
/// The order on screen is the order of the work: words, then photos, then videos. That is
/// deliberate rather than convenient — the words go first precisely so a slow video cannot
/// keep them off the page, and showing the order makes that promise legible.
struct SyncStagesView: View {
    let progress: SyncProgress
    /// Stages this entry has nothing for. Shown greyed and ticked rather than hidden, so the
    /// row does not change shape halfway through and leave somebody wondering what moved.
    let absent: Set<SyncProgress.Stage>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                ForEach(SyncProgress.Stage.allCases, id: \.self) { stage in
                    stagePill(stage)
                    if stage != .videos { connector(after: stage) }
                }
            }

            HStack(spacing: 6) {
                ProgressView(value: progress.fraction)
                    .tint(Brand.violet)
                Text(progress.message)
                    .font(Type.caption(11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .animation(.easeOut(duration: 0.25), value: progress)
    }

    private func stagePill(_ stage: SyncProgress.Stage) -> some View {
        let state = state(of: stage)
        return HStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(state.tint.opacity(state == .waiting ? 0.12 : 0.18))
                    .frame(width: 22, height: 22)
                switch state {
                case .done:
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(state.tint)
                case .working:
                    ProgressView().controlSize(.mini).tint(state.tint)
                case .waiting, .skipped:
                    Image(systemName: stage.symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(state.tint)
                }
            }
            Text(stage.label)
                .font(Type.caption(11, state == .working ? .semibold : .medium))
                .foregroundStyle(state.tint)
        }
    }

    /// A line between the pills that fills in as the work passes it, so the row reads as one
    /// journey rather than three unrelated badges.
    private func connector(after stage: SyncProgress.Stage) -> some View {
        Rectangle()
            .fill(state(of: stage) == .done ? Brand.reached.opacity(0.5) : Brand.muted.opacity(0.2))
            .frame(height: 1.5)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 6)
    }

    private enum StageState {
        case waiting, working, done, skipped

        var tint: Color {
            switch self {
            case .waiting: Brand.muted
            case .working: Brand.violet
            case .done: Brand.reached
            case .skipped: Brand.muted.opacity(0.6)
            }
        }
    }

    private func state(of stage: SyncProgress.Stage) -> StageState {
        if progress.stage == stage { return .working }
        if progress.hasFinished(stage) { return absent.contains(stage) ? .skipped : .done }
        return absent.contains(stage) ? .skipped : .waiting
    }
}
