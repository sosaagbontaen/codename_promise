import Foundation
import Testing

@testable import CodenamePromiseCore

/// A Mac screenshot holds no date inside the file, only in its name. These pin which names
/// are trusted, so screenshots land on their day and an ordinary file name is never dated.
@Suite("Dates from file names")
struct FileNameDateTests {
    let zone = TimeZone(identifier: "America/Chicago")!

    private func stamp(_ name: String) -> String? {
        CaptureDateReader.captureDate(fromFileName: name, timeZone: zone).map {
            let f = DateFormatter()
            f.timeZone = zone
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return f.string(from: $0)
        }
    }

    @Test func macScreenshotsAndRecordings() {
        // The narrow no-break space before AM/PM is what macOS actually writes.
        #expect(stamp("Screenshot 2026-10-21 at 1.00.47\u{202F}AM") == "2026-10-21 01:00:47")
        #expect(stamp("Screenshot 2026-10-21 at 12.05.00 AM") == "2026-10-21 00:05:00")
        #expect(stamp("Screen Shot 2019-05-03 at 10.12.01 PM") == "2019-05-03 22:12:01")
        #expect(stamp("Screen Recording 2026-01-02 at 9.00.00 AM") == "2026-01-02 09:00:00")
        #expect(stamp("WhatsApp Image 2024-07-04 at 18.30.12") == "2024-07-04 18:30:12")
        #expect(stamp("Screenshot 2026-10-21") == "2026-10-21 12:00:00", "no time: midday, so the day can't slip")
    }

    @Test func cameraStyleNames() {
        #expect(stamp("IMG_20261021_130047") == "2026-10-21 13:00:47")
        #expect(stamp("PXL_20250101_000102345") == "2025-01-01 00:01:02")
        #expect(stamp("Screenshot_20240229-081500") == "2024-02-29 08:15:00")
        #expect(stamp("VID_20230815") == "2023-08-15 12:00:00")
    }

    @Test func ordinaryNamesAreNotDated() {
        #expect(stamp("IMG_1234") == nil)
        #expect(stamp("2019 plans") == nil)
        #expect(stamp("receipt 12345678") == nil, "eight digits alone aren't a date")
        #expect(stamp("Screenshot 2026-02-30 at 1.00.00 PM") == nil, "a day that doesn't exist")
        #expect(stamp("Screenshot 2026-13-01") == nil)
        #expect(stamp("5F3A1C2E-0B4D-4E6A-9C1F-2A3B4C5D6E7F") == nil)
    }
}
