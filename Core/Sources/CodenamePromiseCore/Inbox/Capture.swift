import Foundation

/// Something dumped into DumpNotes from somewhere other than the app itself.
///
/// The point of the inbox is that journaling shouldn't need a sit-down session. You remember
/// something on the way out of a meeting, or there is a screenshot on your Mac worth keeping,
/// and it should take thirty seconds to throw it in. Arranging pulls it into shape later.
///
/// A capture is the unit that travels. Two things write them: the share sheet on the phone
/// (into the App Group container) and the Mac capture panel (into a folder in iCloud Drive).
/// One thing reads them: the app, whenever it opens, files each capture into an entry and
/// then deletes it.
///
/// On disk a capture is a folder named by its id, holding its files and a `capture.json`
/// manifest. The manifest is written **last**, and a capture is only taken once every file it
/// lists is present, so a half-synced folder in iCloud Drive is left alone until the rest
/// arrives rather than filed with pieces missing.
public struct Capture: Codable, Sendable, Equatable, Identifiable {
    public static let manifestName = "capture.json"
    public static let currentVersion = 1

    public var version: Int
    public let id: UUID
    public let createdAt: Date
    public var destination: Destination
    /// A quick jot, in the person's own words. Appended to the entry's text, where arranging
    /// will find it.
    public var text: String?
    public var files: [File]
    /// The capture arranged by day: each with its own note, files and entry. When present it
    /// decides everything, and `text` and `destination` are ignored. Absent in captures
    /// written before days existed, and in loose files, which go by `destination`.
    public var groups: [Group]?
    /// Where it came from, for the summary the app shows. `mac`, `share` or `folder`.
    public var source: String

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        destination: Destination = .byCaptureDate,
        text: String? = nil,
        files: [File] = [],
        groups: [Group]? = nil,
        source: String
    ) {
        self.version = Self.currentVersion
        self.id = id
        self.createdAt = createdAt
        self.destination = destination
        self.text = text
        self.files = files
        self.groups = groups
        self.source = source
    }

    /// Where a capture should be filed.
    ///
    /// Kept as plain fields rather than an enum with payloads, because two programs write
    /// this file and a future version may read an older one. A missing `day` means "the day
    /// each thing happened": photos and videos by their own capture date, text by the day it
    /// was jotted.
    public struct Destination: Codable, Sendable, Equatable {
        public var day: CalendarDay?
        /// An entry chosen by the person. Wins over `day` while it still exists.
        public var entryId: UUID?
        /// Start a new entry rather than adding to the day's latest.
        public var newEntry: Bool
        /// Photos and videos go to the day each was taken, while the note goes to `day`.
        /// Optional so a manifest written before it existed still reads.
        public var mediaByCaptureDate: Bool?

        public init(day: CalendarDay?, entryId: UUID? = nil, newEntry: Bool = false, mediaByCaptureDate: Bool = false) {
            self.day = day
            self.entryId = entryId
            self.newEntry = newEntry
            self.mediaByCaptureDate = mediaByCaptureDate ? true : nil
        }

        public static let byCaptureDate = Destination(day: nil)

        /// Whether photos and videos are placed by their own capture date.
        public var filesByCaptureDate: Bool { day == nil || mediaByCaptureDate == true }
    }

    /// One day of a capture.
    public struct Group: Codable, Sendable, Equatable, Identifiable {
        public let id: UUID
        public var day: CalendarDay
        public var entryId: UUID?
        public var newEntry: Bool
        public var text: String?
        public var fileIds: [UUID]
        /// A title for the entry, used only if it doesn't have one yet: naming a new entry
        /// is the point, renaming one someone already titled never is. Absent in captures
        /// written before titles existed, which decode as nil.
        public var title: String?

        public init(id: UUID = UUID(), day: CalendarDay, entryId: UUID? = nil, newEntry: Bool = false,
                    text: String? = nil, fileIds: [UUID] = [], title: String? = nil) {
            self.id = id
            self.day = day
            self.entryId = entryId
            self.newEntry = newEntry
            self.text = text
            self.fileIds = fileIds
            self.title = title
        }
    }

    public struct File: Codable, Sendable, Equatable, Identifiable {
        /// Also the id the attachment gets in the journal, which is what lets the app run
        /// the same capture twice without attaching anything twice.
        public let id: UUID
        /// Relative to the capture's folder.
        public let name: String
        public let kind: Kind

        public init(id: UUID = UUID(), name: String, kind: Kind) {
            self.id = id
            self.name = name
            self.kind = kind
        }
    }

    public enum Kind: String, Codable, Sendable {
        case photo, video, audio, text

        /// Best guess from a file extension. Nil for things the inbox doesn't take.
        public static func infer(fromExtension ext: String) -> Kind? {
            switch ext.lowercased() {
            case "jpg", "jpeg", "heic", "heif", "png", "gif", "tif", "tiff", "webp", "bmp", "dng":
                return .photo
            case "mov", "mp4", "m4v", "hevc", "avi", "3gp":
                return .video
            case "m4a", "mp3", "wav", "aac", "caf", "aiff", "aif":
                return .audio
            case "txt", "md", "markdown", "text":
                return .text
            default:
                return nil
            }
        }
    }

    public var isEmpty: Bool {
        (text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) && files.isEmpty
            && (groups ?? []).allSatisfy { ($0.text ?? "").isEmpty }
    }
}
