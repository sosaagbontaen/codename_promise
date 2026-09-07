import CodenamePromiseCore
import Foundation
import Photos

/// Asks the photo library how many things happened on each day.
///
/// This is the first thing in the app that needs photo library access, and that is a real
/// cost worth being deliberate about. `CaptureDateReader` deliberately avoids it — the
/// picker hands over a file and the file carries its own date, so bulk import needs no
/// permission at all. That trick cannot work here, because the entire point is to know
/// about photos the person has *not* picked.
///
/// So the access is asked for, and three things keep it proportionate:
///
/// - **It is asked for late.** Nothing prompts on launch. The sheet appears when someone
///   opens the missing-days list and asks for this specific help.
/// - **Counts, never pixels.** Producing the numbers enumerates asset metadata and reads no
///   image data at all. Photos are only loaded for a single day, after it has been tapped.
/// - **Declining leaves the feature working.** Without access the missing-days list is
///   exactly what it was before: the days are still there, they just arrive unranked.
enum PhotoLibraryActivity {

    /// What the library will actually answer, in terms the UI can be honest about.
    ///
    /// `limited` is the one that matters and the reason this is not a `Bool`. Under limited
    /// access a fetch returns only the assets the person hand-picked, so the counts come back
    /// quietly too low — a day with forty photos reports two, or nothing at all. Showing that
    /// as though it were the whole library would be confidently wrong, which is the specific
    /// failure `OpenDaysScope` exists to prevent one level up. Same answer here: carry the
    /// scope, and let the UI say which one it got.
    enum Access: Equatable {
        case notAsked
        case granted
        case limited
        case denied
        /// Screen Time or an MDM profile. Asking again cannot change it.
        case restricted

        /// Whether counts from this state describe the whole library.
        var isComplete: Bool { self == .granted }

        var canCount: Bool { self == .granted || self == .limited }
    }

    static var access: Access {
        map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    /// Shows the system sheet, once. Returns the resulting state either way.
    static func request() async -> Access {
        map(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    private static func map(_ status: PHAuthorizationStatus) -> Access {
        switch status {
        case .notDetermined: .notAsked
        case .authorized: .granted
        case .limited: .limited
        case .restricted: .restricted
        case .denied: .denied
        @unknown default: .denied
        }
    }

    /// How many photos and videos were taken on each day in the window.
    ///
    /// Days with nothing on them are absent rather than present with a zero, so the caller
    /// can tell "no photos that day" from "never asked".
    ///
    /// Runs off the main actor: a year of a heavy camera roll is tens of thousands of assets
    /// to walk, and this is called from a view that is already on screen.
    static func counts(
        from: CalendarDay,
        through: CalendarDay,
        timeZone: TimeZone = .current
    ) async -> [CalendarDay: DayActivity] {
        guard access.canCount else { return [:] }

        // Half-open across the whole window: from midnight on the first day up to midnight
        // after the last one, so an 11pm photo on the final day is included.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: from.representativeDate(in: timeZone))
        let end = calendar.startOfDay(
            for: through.adding(days: 1, timeZone: timeZone).representativeDate(in: timeZone)
        )

        return await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(
                format: "creationDate >= %@ AND creationDate < %@",
                start as NSDate, end as NSDate
            )
            // Shared albums and synced-from-Mac assets are other people's days, or old
            // libraries dumped in wholesale. Neither is evidence that *this* person had a
            // day worth writing about.
            options.includeAssetSourceTypes = [.typeUserLibrary]
            options.wantsIncrementalChangeDetails = false

            let assets = PHAsset.fetchAssets(with: options)
            var photos: [CalendarDay: Int] = [:]
            var videos: [CalendarDay: Int] = [:]

            assets.enumerateObjects { asset, _, _ in
                guard let taken = asset.creationDate else { return }

                // Screenshots are the single biggest source of false signal here. Eight
                // screenshots is a day spent arguing with a website, not a day out, and
                // counting them would rank exactly the wrong days to the top. Excluded from
                // the count rather than shown and discounted, because a number the user can
                // see and the app quietly ignores is worse than one that was never claimed.
                if asset.mediaSubtypes.contains(.photoScreenshot) { return }

                let day = CalendarDay(date: taken, timeZone: timeZone)
                switch asset.mediaType {
                case .image: photos[day, default: 0] += 1
                case .video: videos[day, default: 0] += 1
                default: break
                }
            }

            var found: [CalendarDay: DayActivity] = [:]
            for day in Set(photos.keys).union(videos.keys) {
                found[day] = DayActivity(
                    day: day, photos: photos[day] ?? 0, videos: videos[day] ?? 0
                )
            }
            return found
        }.value
    }
}
