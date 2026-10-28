import AVFoundation
import Foundation
import ImageIO

/// Reads when a photo or video was actually taken, from the file itself.
///
/// In Core rather than the app because three things now need it: the bulk import, the
/// capture inbox, and the Mac capture panel.
///
/// This is what makes bulk-import possible without asking for photo library access. The
/// picker hands over the file; the file already carries its own capture date in EXIF (photos)
/// or container metadata (video). PhotoKit would give the same answer but demands read access
/// to the entire library to do it.
///
/// When the file holds no date, its name is the fallback (see `captureDate(fromFileName:)`),
/// which is where a Mac screenshot keeps its date.
///
/// Returns nil rather than guessing. Screenshots, some edited images and anything re-encoded
/// by a messaging app arrive with the metadata stripped, and filing those under today — or
/// under the file's modification date, which is when it was *saved*, not shot — would put
/// photos in the wrong day quietly. An unknown date the user is asked about beats a wrong one
/// they aren't.
public enum CaptureDateReader {

    public static func captureDate(ofImageData data: Data) -> Date? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return captureDate(of: source)
    }

    /// Reads the date from a file without decoding a single pixel of it.
    public static func captureDate(ofImageAt url: URL) -> Date? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil }
        return captureDate(of: source)
    }

    private static func captureDate(of source: CGImageSource) -> Date? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
        else { return nil }

        // EXIF DateTimeOriginal is when the shutter fired. TIFF DateTime is when the file was
        // last written, so it's only a fallback.
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
           let date = exifFormatter.date(from: original) {
            return date
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let stamp = tiff[kCGImagePropertyTIFFDateTime] as? String,
           let date = exifFormatter.date(from: stamp) {
            return date
        }
        return nil
    }

    public static func captureDate(ofVideoAt url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        guard let creationDate = try? await asset.load(.creationDate) else { return nil }
        return try? await creationDate.load(.dateValue)
    }

    /// The date in a file's name, for files that carry none inside them.
    ///
    /// A Mac screenshot is the common case: its PNG holds no date at all, only its size and
    /// a "Screenshot" tag. The date Photos shows for it comes from the file system, which a
    /// share doesn't pass on, but the name nearly always survives and says exactly when it
    /// was taken. Only names in the shape cameras and screenshot tools write are trusted, so a
    /// file someone named "2019 plans" is never dated by accident.
    ///
    /// - "Screenshot 2026-10-21 at 1.00.47 AM", "Screen Shot …", "Screen Recording …",
    ///   "WhatsApp Image 2026-10-21 at 1.00.47 AM": a date, then optionally " at" a time.
    /// - "IMG_20261021_130047", "PXL_20261021_…", "VID_…", "Screenshot_20261021-130047":
    ///   eight digits, then optionally six more for the time.
    public static func captureDate(fromFileName name: String, timeZone: TimeZone = .current) -> Date? {
        // Mac names put a narrow no-break space before AM/PM.
        let name = name.replacingOccurrences(of: "\u{202F}", with: " ")
        var parts: (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int)?

        if let match = name.firstMatch(of: /(?:^|[^0-9])((?:19|20)[0-9]{2})-([0-9]{2})-([0-9]{2})(?: at ([0-9]{1,2})[.:]([0-9]{2})[.:]([0-9]{2})(?: ?([AaPp][Mm]))?)?/) {
            var hour = match.4.flatMap { Int($0) } ?? 12
            if let meridiem = match.7?.lowercased() {
                if meridiem == "pm" && hour < 12 { hour += 12 }
                if meridiem == "am" && hour == 12 { hour = 0 }
            }
            parts = (Int(match.1)!, Int(match.2)!, Int(match.3)!, hour,
                     match.5.flatMap { Int($0) } ?? 0, match.6.flatMap { Int($0) } ?? 0)
        } else if let match = name.firstMatch(of: /(?:IMG|VID|PXL|MVIMG|Screenshot|Screen_Recording|PANO)[_-]((?:19|20)[0-9]{2})([0-9]{2})([0-9]{2})(?:[_-]([0-9]{2})([0-9]{2})([0-9]{2}))?/) {
            parts = (Int(match.1)!, Int(match.2)!, Int(match.3)!,
                     match.4.flatMap { Int($0) } ?? 12, match.5.flatMap { Int($0) } ?? 0, match.6.flatMap { Int($0) } ?? 0)
        }
        guard let parts, (1...12).contains(parts.month), (1...31).contains(parts.day),
              (0...23).contains(parts.hour), (0...59).contains(parts.minute), (0...59).contains(parts.second)
        else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: parts.year, month: parts.month, day: parts.day,
                                        hour: parts.hour, minute: parts.minute, second: parts.second)
        // Rejects a day that doesn't exist, like February 30, rather than rolling it over.
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == parts.day
        else { return nil }
        return date
    }

    /// EXIF timestamps are `yyyy:MM:dd HH:mm:ss` with no timezone — they're local wall-clock
    /// time where the photo was taken. Parsing them in the current timezone is the closest
    /// honest interpretation, and it's what Photos does.
    private static let exifFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
