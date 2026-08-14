import AVFoundation
import Foundation
import ImageIO

/// Reads when a photo or video was actually taken, from the file itself.
///
/// This is what makes bulk-import possible without asking for photo library access. The
/// picker hands over the file; the file already carries its own capture date in EXIF (photos)
/// or container metadata (video). PhotoKit would give the same answer but demands read access
/// to the entire library to do it.
///
/// Returns nil rather than guessing. Screenshots, some edited images and anything re-encoded
/// by a messaging app arrive with the metadata stripped, and filing those under today — or
/// under the file's modification date, which is when it was *saved*, not shot — would put
/// photos in the wrong day quietly. An unknown date the user is asked about beats a wrong one
/// they aren't.
enum CaptureDateReader {

    static func captureDate(ofImageData data: Data) -> Date? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
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

    static func captureDate(ofVideoAt url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        guard let creationDate = try? await asset.load(.creationDate) else { return nil }
        return try? await creationDate.load(.dateValue)
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
