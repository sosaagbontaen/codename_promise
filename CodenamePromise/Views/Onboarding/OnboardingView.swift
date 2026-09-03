import SwiftUI

/// The twenty seconds before someone's first entry.
///
/// One screen, not a carousel. Three facts is not a story, and paging through three facts
/// makes each one feel like a step you have to complete rather than something you were told.
/// The whole thing is readable at a glance and leaves by one button.
///
/// It teaches exactly three things, in this order:
///
/// 1. **Capture is instant** - because the thing people expect from a journalling app is a
///    setup flow, and the answer here is that there isn't one.
/// 2. **Notion is optional** - because the app mentions Notion everywhere and someone who
///    does not use Notion needs to know within seconds that they are not in the wrong place.
/// 3. **Nothing leaves the phone** - last, and given the most weight, because it is the only
///    one of the three a competitor cannot also say.
///
/// That third claim is load-bearing and it is literally true rather than aspirational. There
/// is exactly one `URLSession` in this codebase, it lives in `APIClient`, and it throws
/// `.notConfigured` when no base URL is set - which is how the app ships. On a default
/// install there is no code path off the device at all. Do not soften this copy, and do not
/// strengthen it either: if a backend ever becomes default, this screen has to change first.
struct OnboardingView: View {
    let onDone: () -> Void

    @State private var shown = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                    .padding(.top, 44)
                    .padding(.bottom, 40)

                VStack(alignment: .leading, spacing: 26) {
                    point(
                        symbol: "bolt.fill",
                        tint: Brand.Mode.voice,
                        title: "Nothing to set up",
                        body: "Type it, say it, or drop in a photo. It's saved the moment you make it — before anything else happens."
                    )
                    point(
                        symbol: "cloud",
                        tint: Brand.Mode.text,
                        title: "Notion is optional",
                        body: "Connect a database when you want entries to land there too. Everything works without it."
                    )
                    // The differentiator, and the one worth a raised voice.
                    //
                    // The second sentence is not padding. "Stays on this phone" is accurate
                    // about privacy and, left there, quietly implies that losing the phone
                    // loses the journal - which is the exact fear an app whose first tenet is
                    // "never lose what you wrote" cannot afford to plant. It does not lose it:
                    // the store and the media both live in Application Support and nothing is
                    // marked excluded from backup, so they ride along in the iPhone backup and
                    // come back on a new phone. That is designed for rather than incidental -
                    // every media reference is relative precisely so a restored container with
                    // a different UUID still resolves (ADR-007).
                    point(
                        symbol: "lock.fill",
                        tint: Brand.reached,
                        title: "Your words stay on this phone",
                        body: "No account, no analytics, nothing uploaded. They're part of your iPhone backup, so they follow you to a new phone — and you can export the lot any time.",
                        emphasised: true
                    )
                }
                .padding(.horizontal, 26)

                Spacer(minLength: 36)

                Button {
                    Haptics.picked()
                    onDone()
                } label: {
                    Text("Write your first entry")
                        .font(Type.label(16.5, .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Brand.gradient, in: Capsule())
                }
                .buttonStyle(.pressablePrimary)
                .padding(.horizontal, 26)
                .padding(.top, 30)
                .padding(.bottom, 34)
            }
            .frame(maxWidth: .infinity)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Brand.ground)
        .task {
            withAnimation(.easeOut(duration: 0.45)) { shown = true }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Wordmark(size: 34)
            Text("Capture first. Organize later.")
                .font(Type.body(16))
                .foregroundStyle(Brand.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 26)
    }

    /// A symbol, a claim, and the sentence that makes the claim believable.
    private func point(
        symbol: String,
        tint: Color,
        title: String,
        body: String,
        emphasised: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 15) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(Type.label(16.5, emphasised ? .bold : .semibold))
                    .foregroundStyle(Brand.ink)
                Text(body)
                    .font(Type.body(14.5))
                    // The emphasised point is the one people skim past, so it gets the same
                    // contrast as a title rather than the grey every other explainer uses.
                    .foregroundStyle(emphasised ? Brand.ink.opacity(0.78) : Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
