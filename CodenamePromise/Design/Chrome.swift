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
    static func apply() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.largeTitleTextAttributes = [
            .font: UIFont(name: "Poppins-Bold", size: 32) ?? .systemFont(ofSize: 32, weight: .bold),
            .kern: -0.6,
        ]
        appearance.titleTextAttributes = [
            .font: UIFont(name: "Poppins-SemiBold", size: 17) ?? .systemFont(ofSize: 17, weight: .semibold)
        ]

        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }
}
