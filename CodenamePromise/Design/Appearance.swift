import SwiftUI

/// Light, dark, or whatever the phone says.
///
/// Dark is the default, and deliberately so: the brand was drawn dark, most dumping happens
/// at the end of a day, and the confetti colours are far more alive on a dark ground than a
/// white one. But defaulting is not deciding for someone — the choice is in Settings, and
/// "System" is there for people who switch with the sun.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appearance"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
