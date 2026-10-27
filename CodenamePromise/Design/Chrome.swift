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
    /// The system navigation bar, as is. It used to be dressed in Poppins, which was most of
    /// why the app looked like a template; the stock bar is what makes it look native.
    static func apply() {}
}
