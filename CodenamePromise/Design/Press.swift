import SwiftUI

/// Why a `.buttonStyle(.plain)` control feels like a picture of a button.
///
/// `.plain` removes the default press treatment and puts nothing back, so the only feedback
/// is the thing you tapped eventually doing something. Every custom control in the app had
/// this problem: statically fine, and dead on contact.
///
/// A press should be felt in three ways at once — it shrinks, it dims slightly, and it taps
/// back. The spring is deliberately quick and slightly under-damped so release has a little
/// life in it rather than sliding back linearly.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.94
    var haptic: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.62), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                // On press rather than on release: the feedback should arrive when the
                // finger lands, which is when a physical button would have moved.
                if pressed && haptic { Haptics.picked() }
            }
    }
}

/// For a full-width row, where scaling looks wrong but nothing at all feels broken.
///
/// iOS gives `List` rows a highlight for free, and both of the things this app does to its
/// rows take it away: `.listRowBackground(.clear)` leaves nothing to tint, and
/// `.buttonStyle(.plain)` strips the treatment without replacing it. The result is an app
/// where tapping produces no acknowledgement until the next screen arrives - which reads as
/// unresponsive even when it is fast.
struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Brand.ink.opacity(configuration.isPressed ? 0.07 : 0))
                    .padding(.horizontal, -10)
            )
            // Dims as well as tints. The tint sits *behind* the label, which worked while
            // rows were transparent and stopped working the moment an entry started drawing
            // its own opaque card - the highlight was still there, painted underneath
            // something you cannot see through. Dimming the label survives either.
            .opacity(configuration.isPressed ? 0.88 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { Haptics.picked() }
            }
    }
}

extension ButtonStyle where Self == RowPressStyle {
    static var row: RowPressStyle { RowPressStyle() }
}

extension ButtonStyle where Self == PressableStyle {
    /// For a large primary action, where a big surface makes a big scale look wrong.
    static var pressablePrimary: PressableStyle { PressableStyle(scale: 0.975) }
    /// For small round controls, which can take a firmer squeeze.
    static var pressable: PressableStyle { PressableStyle(scale: 0.9) }
}

extension View {
    /// Dismisses the keyboard from anywhere.
    func hideKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }
}
