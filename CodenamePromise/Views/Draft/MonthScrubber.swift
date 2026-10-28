import SwiftUI

/// How far the journal is scrolled, 0 to 1, kept apart from the journal itself.
///
/// It changes every frame of a scroll. Held in the journal's own state, every one of those
/// frames re-ran the journal's whole body, regrouping and diffing a few thousand entries, just
/// to move a handle. Here only the scrubber reads it, so only the scrubber redraws.
@MainActor
@Observable
final class ScrollProgressTracker {
    /// Nil when it isn't known (before iOS 18), and the handle stays put.
    var progress: CGFloat?
}

/// A fast-scroll handle for the journal, like the one in Photos. It replaces the system
/// scroll bar: it tracks the scroll position, and grabbing it jumps by month.
///
/// At rest it's a slim handle on the right edge, over the content, taking no room from it.
/// Scrolling wakes it into a tab that can be grabbed, and nothing more: the months only fade
/// in once a finger is on the handle itself, the one under the finger highlighted, and the
/// journal jumps as the finger moves. Let go and they fade away again. Showing the months on
/// every scroll covered the entries being read and invited jumping somewhere by accident.
///
/// Built for a journal that spans years: when there are more months than fit, the column
/// shows evenly spaced labels, but the finger still moves through every single month.
struct MonthScrubber: View {
    struct Month: Identifiable, Equatable {
        /// `yyyy-MM`, also the id of the month's section to scroll to.
        let id: String
        /// "Oct '26".
        let short: String
        /// "October 2026".
        let full: String
    }

    let months: [Month]
    /// How far through the journal the list is scrolled, so the handle doubles as the
    /// scroll bar.
    let tracker: ScrollProgressTracker
    let onSelect: (String) -> Void

    private var progress: CGFloat? { tracker.progress }

    @State private var active: Int?
    /// True only while a finger is on the handle. Gesture state, so it resets itself if the
    /// touch is cancelled (a notification, a system gesture) rather than staying stuck on.
    @GestureState private var touching = false
    /// Whether the touch now under way began on the handle. Decided on its first movement
    /// and cleared when it ends. A touch that began anywhere else never moves the journal,
    /// whatever the gesture system hands this view.
    @State private var grabbed = false
    private var dragging: Bool { touching && grabbed }
    /// True for a moment after the list moves, so the handle shows itself while scrolling:
    /// the moment someone might want it is when they're already scrolling.
    @State private var awake = false
    /// When the list last moved. Not state the body reads, so writing it every frame of a
    /// scroll redraws nothing.
    @State private var lastMoved = LastMoved()
    private final class LastMoved { var at = Date.distantPast }
    /// Where along the edge the handle sits, 0 at the top to 1 at the bottom.
    @State private var position: CGFloat = 0

    private let rowHeight: CGFloat = 22
    private let handleHeight: CGFloat = 46
    /// Room per month in a short journal: a pill and a comfortable gap.
    private let monthSpacing: CGFloat = 34
    /// Where a drag in a short journal began, and the month showing then.
    @State private var dragStart: (y: CGFloat, index: Int)?

    /// A short journal: every month fits down the edge at `monthSpacing`.
    ///
    /// Spreading a few months down the whole edge put them hundreds of points apart, too far
    /// to read as one column. So a short journal gets a tight column that rides with the
    /// handle, the current month beside it, and dragging steps a month per `monthSpacing`.
    /// A long journal keeps the full-height track, where every point of the edge is a month.
    private func isCompact(_ height: CGFloat) -> Bool {
        CGFloat(months.count) * monthSpacing < height
    }

    /// The month the list is showing, as far as the scroll position says.
    private var currentIndex: Int {
        guard months.count > 1 else { return 0 }
        let fraction = min(max(progress ?? position, 0), 1)
        return Int((fraction * CGFloat(months.count - 1)).rounded())
    }

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let compact = isCompact(height)
            // Follows the scroll, except while it's being dragged, when it follows the finger.
            let shown = dragging ? position : (progress ?? position)
            let handleY = shown * max(height - handleHeight, 0)
            let handleCenter = handleY + handleHeight / 2
            let anchor = dragging ? (active ?? currentIndex) : currentIndex

            ZStack(alignment: .topTrailing) {
                // The months, only while a finger is on the handle.
                if dragging {
                    labels(height: height) { index in
                        compact
                            ? handleCenter + CGFloat(index - anchor) * monthSpacing
                            : center(of: index, height: height)
                    }
                    .transition(.opacity)
                }

                // The handle, flush with the edge like a scroll bar. Awake, it becomes a tab you
                // can see is meant to be held.
                Group {
                    if dragging || awake {
                        Capsule()
                            .fill(Brand.violet)
                            .frame(width: 26, height: handleHeight)
                            .overlay {
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .shadow(color: .black.opacity(0.3), radius: 4)
                    } else {
                        Capsule()
                            .fill(Brand.muted.opacity(0.6))
                            .frame(width: 5, height: handleHeight)
                    }
                }
                .padding(.trailing, 3)
                // The tab itself and nothing around it. A wider strip down the edge caught
                // ordinary scrolls that happened to start near it, and the scrubber took the
                // touch and jumped instead of the list scrolling.
                .frame(width: 30, height: handleHeight, alignment: .trailing)
                .contentShape(Rectangle())
                .offset(y: handleY)
                // Only grabbable once it's showing, as in Photos. The slim line at rest sits
                // where a thumb lands to scroll, and grabbing it there jumped by accident.
                .allowsHitTesting(dragging || awake)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("scrubber"))
                        .updating($touching) { _, state, _ in state = true }
                        .onChanged { value in
                            if !grabbed {
                                // Only a touch that started on the tab as it was drawn then.
                                let start = value.startLocation
                                let onHandle = start.x >= geometry.size.width - 34
                                    && abs(start.y - handleCenter) <= handleHeight / 2 + 6
                                guard onHandle else { return }
                                grabbed = true
                            }
                            // Nothing jumps until the finger has deliberately moved up or down.
                            // A touch that merely lands on the tab, say partway through a run
                            // of flicks, shows the months and goes no further.
                            if active == nil, abs(value.translation.height) < 8 { return }
                            move(to: value.location.y, height: height)
                        }
                )
            }
            .frame(width: geometry.size.width, height: height, alignment: .topTrailing)
        }
        .coordinateSpace(name: "scrubber")
        .animation(.easeOut(duration: 0.15), value: dragging)
        .animation(.easeOut(duration: 0.2), value: awake)
        .onChange(of: touching) { _, now in
            if !now {
                grabbed = false
                active = nil
                dragStart = nil
            }
        }
        .onChange(of: progress) { _, _ in
            lastMoved.at = .now
            if !awake { awake = true }
        }
        // Settles back to a slim line a moment after the scrolling stops. One task per time
        // it wakes, not one per frame of scrolling, sleeping until the last movement is old.
        .task(id: awake) {
            guard awake else { return }
            while !Task.isCancelled {
                let remaining = 1.4 - Date.now.timeIntervalSince(lastMoved.at)
                if remaining <= 0, !dragging {
                    awake = false
                    return
                }
                try? await Task.sleep(for: .seconds(max(remaining, 0.3)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Jump to month")
        // Guarded: the journal can lose months (a delete) while one is still marked active.
        .accessibilityValue(active.flatMap { months.indices.contains($0) ? months[$0].full : nil } ?? "")
        .accessibilityAdjustableAction { direction in
            let index = active ?? 0
            let next = direction == .increment ? min(index + 1, months.count - 1) : max(index - 1, 0)
            guard months.indices.contains(next) else { return }
            active = next
            onSelect(months[next].id)
        }
    }

    /// The months along the full height of the track, each one placed exactly where the
    /// finger has to be to choose it, so the highlighted month is always beside the thumb.
    ///
    /// They used to sit stacked in a small box in the middle while the finger was measured
    /// against the whole edge, so the highlighted month could be half a screen away from it.
    private func labels(height: CGFloat, centerOf: @escaping (Int) -> CGFloat) -> some View {
        let rows = visibleRows(fitting: height)
        return ZStack(alignment: .topTrailing) {
            // Each month on its own small pill rather than one strip down the screen, which
            // covered the content for nothing between the labels.
            Color.clear.frame(width: 1, height: height)

            ForEach(rows, id: \.self) { index in
                let isActive = dragging && (active.map { nearestRow(to: $0, in: rows) == index } ?? false)
                let activeIndex = active.flatMap { months.indices.contains($0) ? $0 : nil } ?? index
                Text(isActive ? months[activeIndex].full : months[index].short)
                    .font(.system(size: isActive ? 14 : 11, weight: isActive ? .bold : .semibold))
                    .foregroundStyle(isActive ? .white : Brand.ink.opacity(0.8))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, isActive ? 12 : 8)
                    .frame(height: rowHeight)
                    .background {
                        if isActive {
                            Capsule().fill(Brand.violet)
                        } else {
                            Capsule().fill(.ultraThinMaterial)
                        }
                    }
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    .offset(y: centerOf(index) - rowHeight / 2)
            }
        }
        .frame(height: height, alignment: .topTrailing)
        .padding(.trailing, 44)
        .allowsHitTesting(false)
    }

    /// Where along the track a month sits: the middle of its share of the height, the same
    /// mapping the finger uses to pick one.
    private func center(of index: Int, height: CGFloat) -> CGFloat {
        (CGFloat(index) + 0.5) / CGFloat(max(months.count, 1)) * height
    }

    /// Every month if they fit, otherwise evenly spaced ones, always including the first and
    /// last so the column reads as the whole span.
    private func visibleRows(fitting height: CGFloat) -> [Int] {
        let capacity = max(2, Int((height - 12) / rowHeight))
        guard months.count > capacity else { return Array(months.indices) }
        return (0..<capacity).map { slot in
            Int((Double(slot) / Double(capacity - 1) * Double(months.count - 1)).rounded())
        }
    }

    private func nearestRow(to index: Int, in rows: [Int]) -> Int {
        rows.min { abs($0 - index) < abs($1 - index) } ?? index
    }

    /// The finger's place along the edge, as a month: every month, labelled or not.
    private func move(to y: CGFloat, height: CGFloat) {
        guard !months.isEmpty, height > 0 else { return }
        let fraction = min(max(y / height, 0), 0.9999)
        position = fraction
        let index: Int
        if isCompact(height) {
            // A month per step of the finger, counted from where the drag began, so the
            // highlighted month is always the one beside the thumb.
            let start = dragStart ?? (y, currentIndex)
            dragStart = start
            let steps = Int(((y - start.y) / monthSpacing).rounded())
            index = min(max(start.index + steps, 0), months.count - 1)
        } else {
            index = Int(fraction * CGFloat(months.count))
        }
        guard index != active else { return }
        active = index
        Haptics.picked()
        onSelect(months[index].id)
    }
}
