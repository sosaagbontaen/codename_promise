import SwiftUI
import UIKit

/// Makes UIKit's chrome wear the app's typeface.
///
/// SwiftUI's `navigationTitle` renders through `UINavigationBar`, which knows nothing about
/// the fonts the rest of the app uses. Leaving it alone means the largest text on the screen
/// is the one piece still speaking in the system voice — which is most of why an app reads as
/// a default project no matter what happens below the bar.
///
/// Set once at launch. `UIFont` rather than `Font` because this is UIKit's appearance proxy,
/// and the variable weight axis has to be selected explicitly here too — asking for "Sora"
/// alone yields its default instance.
enum Chrome {
    private static let weightAxis = 0x77676874  // 'wght'

    static func apply() {
        let large = font("Sora", size: 32, weight: 700)
        let inline = font("Sora", size: 17, weight: 600)

        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.largeTitleTextAttributes = [.font: large, .kern: -0.8]
        appearance.titleTextAttributes = [.font: inline]

        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }

    private static func font(_ family: String, size: CGFloat, weight: CGFloat) -> UIFont {
        let descriptor = UIFontDescriptor(fontAttributes: [
            .family: family,
            kCTFontVariationAttribute as UIFontDescriptor.AttributeName: [weightAxis: weight],
        ])
        return UIFont(descriptor: descriptor, size: size)
    }
}
