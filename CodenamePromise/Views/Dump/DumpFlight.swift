import SwiftUI

/// The moment the app is named after.
///
/// Pressing "Dump it" used to be a state change: the box emptied and a screen appeared.
/// Correct, and nothing *happened* — which is most of why the app read as flat.
///
/// Now it is an impact, in three beats:
///
/// 1. **The plunge.** Each captured piece accelerates toward the tray. Deliberately eased
///    *in* rather than sprung, so it gathers speed instead of gently arriving — the whole
///    point is that they fall.
/// 2. **The hit.** They converge, a shockwave ring snaps outward, the tray flashes, and a
///    heavy haptic lands. This is the frame the animation exists for.
/// 3. **The spray.** Confetti bursts back up and out in the mode colours, arcing and fading,
///    because a tray full of things landing should throw a little back.
///
/// Total ~620ms. Longer than the 420 it replaced, and still under the threshold where
/// dumping twice in a row starts to feel like queuing.
struct DumpFlight: View {
    struct Piece: Identifiable {
        let id = UUID()
        let symbol: String
        let tint: Color
        let origin: CGPoint
        let delay: Double
    }

    /// A single spark thrown back out of the tray on impact.
    struct Spark: Identifiable {
        let id = UUID()
        let angle: Double
        let distance: CGFloat
        let size: CGFloat
        let tint: Color
    }

    enum Phase { case idle, falling, impact }

    let pieces: [Piece]
    let destination: CGPoint
    let phase: Phase

    /// Fixed rather than random per frame, so the burst is the same shape every time and
    /// reads as the app's gesture rather than as noise.
    private static let sparks: [Spark] = makeSparks()

    private static func makeSparks() -> [Spark] {
        let tints: [Color] = [Brand.Mode.text, Brand.Mode.voice, Brand.Mode.photo,
                              Brand.Mode.video, Brand.Mode.extra]
        var result: [Spark] = []
        for i in 0..<14 {
            let fraction = Double(i) / 14.0
            let angle: Double = -Double.pi + fraction * Double.pi
            let distance = CGFloat(54 + (i * 37) % 46)
            let size = CGFloat(5 + (i * 13) % 5)
            result.append(Spark(angle: angle, distance: distance,
                                size: size, tint: tints[i % tints.count]))
        }
        return result
    }

    var body: some View {
        ZStack {
            shockwave
            spray
            plunging
        }
        .allowsHitTesting(false)
    }

    // MARK: Beat 1 — the plunge

    private var plunging: some View {
        ForEach(pieces) { piece in
            Image(systemName: piece.symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(piece.tint)
                .frame(width: 44, height: 44)
                .background(piece.tint.opacity(0.16), in: Circle())
                .scaleEffect(phase == .idle ? 1 : 0.28)
                .opacity(phase == .idle ? 1 : 0)
                .position(phase == .idle ? piece.origin : destination)
                .animation(
                    // easeIn, not a spring: they should accelerate into the tray.
                    .easeIn(duration: 0.3).delay(piece.delay),
                    value: phase
                )
        }
    }

    // MARK: Beat 2 — the hit

    private var shockwave: some View {
        ZStack {
            Circle()
                .strokeBorder(Brand.violet, lineWidth: phase == .impact ? 1.5 : 8)
                .frame(width: phase == .impact ? 190 : 26,
                       height: phase == .impact ? 190 : 26)
                .opacity(phase == .impact ? 0 : 0.9)

            Circle()
                .fill(Brand.violet)
                .frame(width: phase == .impact ? 120 : 20,
                       height: phase == .impact ? 120 : 20)
                .opacity(phase == .impact ? 0 : 0.35)
                .blur(radius: 12)
        }
        .position(destination)
        .opacity(phase == .idle ? 0 : 1)
        .animation(.easeOut(duration: 0.42), value: phase)
    }

    // MARK: Beat 3 — the spray

    private var spray: some View {
        ForEach(Self.sparks) { spark in
            Circle()
                .fill(spark.tint)
                .frame(width: spark.size, height: spark.size)
                .position(
                    x: destination.x + (phase == .impact ? cos(spark.angle) * spark.distance : 0),
                    y: destination.y + (phase == .impact ? sin(spark.angle) * spark.distance : 0)
                )
                .opacity(phase == .impact ? 0 : (phase == .idle ? 0 : 1))
                .scaleEffect(phase == .impact ? 0.4 : 1)
                .animation(.easeOut(duration: 0.5), value: phase)
        }
    }
}

/// The tray reacting to what is about to land in it.
///
/// A tab-bar icon that never changes is furniture. This one fills the moment something is
/// staged, so the app is doing something between your inputs rather than only during them.
struct TrayBadge: View {
    let count: Int

    var body: some View {
        ZStack {
            Image(systemName: count > 0 ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
            if count > 0 {
                Circle()
                    .fill(Brand.Mode.video)
                    .frame(width: 8, height: 8)
                    .offset(x: 11, y: -9)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: count)
    }
}
