import SwiftUI

/// The tray from the app icon, with a face: what an empty screen shows instead of a line of
/// grey text.
///
/// One character drawn in code rather than a set of pictures, so every empty state is a
/// variation on the same one: a mood (where it looks, whether it's smiling) and a few of the
/// icon's own tiles floating over it. Moving gently, blinking now and then, still when the
/// system asks for reduced motion.
struct Mascot: View {
    enum Mood {
        /// Looking up at what might land: an empty day, an empty journal.
        case waiting
        /// Eyes moving side to side: search, before anything's typed.
        case searching
        /// A flat mouth: nothing matched, or something's gone.
        case puzzled
        /// Eyes closed in a smile: nothing to do, which is good news.
        case content
    }

    /// The icon's tiles, floating over the tray.
    enum Prop: Hashable {
        case note, photo, mic, video, magnifier, laptop, sparkle

        var symbol: String {
            switch self {
            case .note: "text.alignleft"
            case .photo: "photo.fill"
            case .mic: "mic.fill"
            case .video: "play.fill"
            case .magnifier: "magnifyingglass"
            case .laptop: "laptopcomputer"
            case .sparkle: "sparkles"
            }
        }

        var tint: Color {
            switch self {
            case .note: Brand.Mode.extra
            case .photo: Brand.Mode.photo
            case .mic: Brand.Mode.text
            case .video: Brand.Mode.video
            case .magnifier, .laptop, .sparkle: Brand.violet
            }
        }
    }

    var mood: Mood = .waiting
    var props: [Prop] = []
    /// The width it's drawn at; it's designed at 200.
    var width: CGFloat = 140

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let canvas = CGSize(width: 200, height: 204)

    var body: some View {
        let scale = width / Self.canvas.width
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .topLeading) {
                ForEach(Array(props.prefix(3).enumerated()), id: \.element) { index, prop in
                    tile(prop, slot: index, of: min(props.count, 3), t: t)
                }
                tray(t: t)
                    .offset(y: 64 + (reduceMotion ? 0 : sin(t * 1.4) * 1.5))
            }
            .frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
        }
        .frame(width: width, height: Self.canvas.height * scale, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    // MARK: - Tiles

    private func tile(_ prop: Prop, slot: Int, of count: Int, t: Double) -> some View {
        // Fanned over the tray's mouth, the middle one highest, like the icon.
        let spots: [[CGPoint]] = [
            [CGPoint(x: 100, y: 22)],
            [CGPoint(x: 68, y: 26), CGPoint(x: 132, y: 18)],
            [CGPoint(x: 48, y: 30), CGPoint(x: 100, y: 12), CGPoint(x: 152, y: 26)],
        ]
        let spot = spots[max(count - 1, 0)][slot]
        let phase = Double(slot) * 1.9
        let bob = sin(t * 1.8 + phase) * 4
        let tilt = [-12.0, 4, 14][slot % 3] + sin(t * 1.3 + phase) * 4
        return ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(prop.tint)
            Image(systemName: prop.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 34, height: 34)
        .shadow(color: prop.tint.opacity(0.35), radius: 6, y: 3)
        .rotationEffect(.degrees(tilt))
        .position(x: spot.x, y: spot.y + 17 + bob)
    }

    // MARK: - Tray

    private func tray(t: Double) -> some View {
        ZStack(alignment: .topLeading) {
            TrayOutline(closed: true)
                .fill(Brand.monthBand)
            FrontPanel()
                .fill(Brand.violet)
                .clipShape(TrayOutline(closed: true))
            FrontPanel(edgeOnly: true)
                .stroke(Brand.violetDeep, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                .clipShape(TrayOutline(closed: true))
            TrayOutline(closed: false)
                .stroke(Brand.violetDeep, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            face(t: t)
        }
        .frame(width: 200, height: 140, alignment: .topLeading)
    }

    private func face(t: Double) -> some View {
        // A blink lasts about a tenth of a second, every few seconds.
        let blinking = !reduceMotion && t.truncatingRemainder(dividingBy: 3.7) < 0.12
        let look: CGSize = switch mood {
        case .waiting: CGSize(width: 0, height: -2.5)
        case .searching: CGSize(width: sin(t * 1.6) * 3, height: 0)
        case .puzzled: CGSize(width: 2, height: 1)
        case .content: .zero
        }
        return ZStack {
            if mood == .content {
                ForEach([78.0, 122.0], id: \.self) { x in
                    ClosedEye()
                        .stroke(.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .frame(width: 14, height: 7)
                        .position(x: x, y: 104)
                }
            } else {
                ForEach([78.0, 122.0], id: \.self) { x in
                    ZStack {
                        Ellipse().fill(.white).frame(width: 15, height: 18)
                        Ellipse().fill(Brand.night).frame(width: 8, height: 9.5)
                            .offset(look)
                    }
                    .scaleEffect(y: blinking ? 0.12 : 1)
                    .position(x: x, y: 104)
                }
            }
            // Cheeks.
            ForEach([62.0, 138.0], id: \.self) { x in
                Ellipse().fill(Color.pink.opacity(0.35)).frame(width: 12, height: 7)
                    .position(x: x, y: 116)
            }
            Mouth(smile: mood == .puzzled ? 0 : 1)
                .stroke(.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .frame(width: mood == .puzzled ? 12 : 18, height: 7)
                .position(x: 100, y: 121)
        }
        .frame(width: 200, height: 140)
    }
}

/// The tray's walls: flared tips at the top, straight sides, a rounded bottom. Open at the
/// top for the stroke, closed for the fill.
private struct TrayOutline: Shape {
    var closed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 14, y: 6))
        path.addQuadCurve(to: CGPoint(x: 24, y: 22), control: CGPoint(x: 24, y: 8))
        path.addLine(to: CGPoint(x: 26, y: 112))
        path.addQuadCurve(to: CGPoint(x: 48, y: 134), control: CGPoint(x: 26, y: 134))
        path.addLine(to: CGPoint(x: 152, y: 134))
        path.addQuadCurve(to: CGPoint(x: 174, y: 112), control: CGPoint(x: 174, y: 134))
        path.addLine(to: CGPoint(x: 176, y: 22))
        path.addQuadCurve(to: CGPoint(x: 186, y: 6), control: CGPoint(x: 176, y: 8))
        if closed { path.closeSubpath() }
        return path
    }
}

/// The front of the tray, with the dip in its top edge the icon has.
private struct FrontPanel: Shape {
    var edgeOnly = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 64))
        path.addLine(to: CGPoint(x: 58, y: 64))
        path.addQuadCurve(to: CGPoint(x: 72, y: 80), control: CGPoint(x: 66, y: 64))
        path.addLine(to: CGPoint(x: 128, y: 80))
        path.addQuadCurve(to: CGPoint(x: 142, y: 64), control: CGPoint(x: 134, y: 64))
        path.addLine(to: CGPoint(x: 200, y: 64))
        if !edgeOnly {
            path.addLine(to: CGPoint(x: 200, y: 140))
            path.addLine(to: CGPoint(x: 0, y: 140))
            path.closeSubpath()
        }
        return path
    }
}

private struct ClosedEye: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY - rect.height))
        return path
    }
}

private struct Mouth: Shape {
    /// 1 is a smile, 0 a flat line.
    var smile: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.3))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.3),
                          control: CGPoint(x: rect.midX, y: rect.minY + rect.height * (0.3 + 1.4 * smile)))
        return path
    }
}

/// An empty screen: the mascot, a few words, and what to do about it.
struct EmptyState<Actions: View>: View {
    let title: String
    var message: String?
    var mood: Mascot.Mood = .waiting
    var props: [Mascot.Prop] = []
    var mascotWidth: CGFloat = 140
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 10) {
            Mascot(mood: mood, props: props, width: mascotWidth)
                .padding(.bottom, 4)
            Text(title)
                .font(Type.label(17, .semibold))
                .foregroundStyle(Brand.ink)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(Type.body(14))
                    .foregroundStyle(Brand.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
            actions()
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension EmptyState where Actions == EmptyView {
    init(_ title: String, message: String? = nil, mood: Mascot.Mood = .waiting,
         props: [Mascot.Prop] = [], mascotWidth: CGFloat = 140) {
        self.init(title: title, message: message, mood: mood, props: props,
                  mascotWidth: mascotWidth, actions: { EmptyView() })
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 40) {
            EmptyState("No entries yet", message: "Add a note, photo, or memory from this day.", props: [.note, .photo, .mic])
            EmptyState("Search your journal", mood: .searching, props: [.magnifier])
            EmptyState("Nothing found", mood: .puzzled)
            EmptyState("Nothing here", mood: .content, props: [.sparkle])
        }
        .padding()
    }
    .background(Brand.ground)
}
