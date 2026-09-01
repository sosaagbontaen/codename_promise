import SwiftUI

/// Choosing which mark sits on the home screen.
///
/// The brand sheet ships several good variants and only one of them can be the default, so
/// the rest may as well be offered. iOS supports this natively through
/// `setAlternateIconName`; the icons are registered in the asset catalog and listed in the
/// target's `ALTERNATE_APPICON_NAMES`.
///
/// Two things about the API worth knowing, because both are easy to trip over: the name is
/// `nil` for the primary icon rather than its actual name, and iOS shows its own "You have
/// changed the icon" alert that cannot be suppressed on a shipping build.
struct AppIconPicker: View {
    /// `nil` means the primary icon.
    struct Choice: Identifiable {
        let id: String
        /// `nil` selects the primary icon - the API's convention, not a missing value.
        let name: String?
        let label: String
        /// A normal imageset, because an appiconset is not loadable as a `UIImage` in-app.
        /// Registering the alternates is what makes them *selectable*; drawing a preview of
        /// one is a separate problem, and this is its answer.
        let preview: String
    }

    static let choices: [Choice] = [
        Choice(id: "primary", name: nil, label: "Dark", preview: "IconPreview-Dark"),
        Choice(id: "AppIcon-Light", name: "AppIcon-Light", label: "Light", preview: "IconPreview-Light"),
        Choice(id: "AppIcon-Gradient", name: "AppIcon-Gradient", label: "Gradient", preview: "IconPreview-Gradient"),
        Choice(id: "AppIcon-Monogram", name: "AppIcon-Monogram", label: "DN", preview: "IconPreview-Monogram"),
        Choice(id: "AppIcon-Mono", name: "AppIcon-Mono", label: "DN Light", preview: "IconPreview-Mono"),
    ]

    @State private var current: String?
    @State private var failure: String?

    var body: some View {
        Section {
            // All five fit at once. They were in a horizontal scroll at 62pt, which pushed
            // the fifth off the edge - so the answer to "where are the rest" was "keep
            // swiping", which is not an answer.
            HStack(spacing: 8) {
                    ForEach(Self.choices) { choice in
                        Button {
                            select(choice)
                        } label: {
                            IconTile(
                                choice: choice,
                                selected: choice.name == current
                            )
                        }
                        .buttonStyle(.pressable)
                    }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(Type.caption(12))
                    .foregroundStyle(Brand.failed)
            }
        } header: {
            Text("App icon")
        } footer: {
            Text("iOS shows its own confirmation when the icon changes \u{2014} that alert is Apple's, not ours.")
        }
        .task { current = UIApplication.shared.alternateIconName }
    }

    private func select(_ choice: Choice) {
        guard UIApplication.shared.supportsAlternateIcons else {
            failure = "This device doesn't support changing the icon."
            return
        }
        guard choice.name != current else { return }

        UIApplication.shared.setAlternateIconName(choice.name) { error in
            Task { @MainActor in
                if let error {
                    failure = error.localizedDescription
                } else {
                    failure = nil
                    current = choice.name
                    Haptics.landed()
                }
            }
        }
    }
}

private struct IconTile: View {
    let choice: AppIconPicker.Choice
    let selected: Bool

    var body: some View {
        VStack(spacing: 7) {
            preview
                .frame(width: 54, height: 54)
                // Apple's own corner curve, so the tile looks like a home screen icon
                // rather than a rounded picture of one.
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(selected ? Brand.violet : Color.clear, lineWidth: 2.5)
                        .padding(-3)
                }

            Text(choice.label)
                .font(Type.caption(10, .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(selected ? Brand.violet : Brand.muted)
        }
        .frame(maxWidth: .infinity)
    }

    /// The asset is included as a normal image because the target sets
    /// `INCLUDE_ALL_APPICON_ASSETS`; without that an alternate icon exists for the system
    /// but cannot be drawn in-app.
    @ViewBuilder
    private var preview: some View {
        if let image = UIImage(named: choice.preview) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Brand.surface
                .overlay { Image(systemName: "app.dashed").foregroundStyle(Brand.muted) }
        }
    }
}
