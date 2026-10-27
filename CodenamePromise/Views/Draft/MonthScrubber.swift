import SwiftUI

/// A fast-scroll handle for the journal, like the one in Photos. It replaces the system
/// scroll bar: it tracks the scroll position, and grabbing it jumps by month.
///
/// At rest it's a slim handle on the right edge, over the content, taking no room from it.
/// Grab it and the months fade in beside it, the one under the finger highlighted, with a
/// bubble giving its full name, and the journal jumps as the finger moves. Let go and they
/// fade away again.
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
    /// How far through the journal the list is scrolled, 0 to 1, so the handle doubles as the
    /// scroll bar. Nil when it isn't known (before iOS 18), and the handle stays put.
    var progress: CGFloat?
    let onSelect: (String) -> Void

    @State private var active: Int?
    /// True only while a finger is on the handle. Gesture state, so it resets itself if the
    /// touch is cancelled (a notification, a system gesture) rather than staying stuck on.
    @GestureState private var touching = false
    private var dragging: Bool { touching }
    /// True for a moment after the list moves, so the handle shows itself while scrolling:
    /// the moment someone might want it is when they're already scrolling.
    @State private var awake = false
    /// Where along the edge the handle sits, 0 at the top to 1 at the bottom.
    @State private var position: CGFloat = 0

    private let rowHeight: CGFloat = 22
    private let handleHeight: CGFloat = 46

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            // Follows the scroll, except while it's being dragged, when it follows the finger.
            let shown = dragging ? position : (progress ?? position)
            let handleY = shown * max(height - handleHeight, 0)

            ZStack(alignment: .topTrailing) {
                // Every month, whenever the handle is awake, so you can see where you could go
                // before touching it. Only the one under the finger is highlighted.
                if dragging || awake {
                    labels(height: height)
                        .transition(.opacity)
                }

                // The handle, flush with the edge like a scroll bar, in a target big enough to
                // catch with a thumb. Awake, it becomes a tab you can see is meant to be held.
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
                .frame(width: 44, height: handleHeight + 24, alignment: .trailing)
                .contentShape(Rectangle())
                .offset(y: handleY - 12)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("scrubber"))
                        .updating($touching) { _, state, _ in state = true }
                        .onChanged { value in move(to: value.location.y, height: height) }
                )
            }
            .frame(width: geometry.size.width, height: height, alignment: .topTrailing)
        }
        .coordinateSpace(name: "scrubber")
        .animation(.easeOut(duration: 0.15), value: dragging)
        .animation(.easeOut(duration: 0.2), value: awake)
        .onChange(of: touching) { _, now in
            if !now { active = nil }
        }
        .onChange(of: progress) { _, _ in
            awake = true
        }
        // Settles back to a slim line a moment after the scrolling stops.
        .task(id: progress) {
            try? await Task.sleep(for: .seconds(1.4))
            if !Task.isCancelled { awake = false }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Jump to month")
        .accessibilityValue(active.map { months[$0].full } ?? "")
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
    private func labels(height: CGFloat) -> some View {
        let rows = visibleRows(fitting: height)
        return ZStack(alignment: .topTrailing) {
            // Each month on its own small pill rather than one strip down the screen, which
            // covered the content for nothing between the labels.
            Color.clear.frame(width: 1, height: height)

            ForEach(rows, id: \.self) { index in
                let isActive = dragging && (active.map { nearestRow(to: $0, in: rows) == index } ?? false)
                Text(isActive ? months[active ?? index].full : months[index].short)
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
                    .offset(y: center(of: index, height: height) - rowHeight / 2)
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
        let index = Int(fraction * CGFloat(months.count))
        guard index != active else { return }
        active = index
        Haptics.picked()
        onSelect(months[index].id)
    }
}
