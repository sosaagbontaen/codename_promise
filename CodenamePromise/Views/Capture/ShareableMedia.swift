import CodenamePromiseCore
import Foundation

/// A photo or video ready to hand to the share sheet under a readable name.
///
/// Every attachment is stored as "original.jpg" in a folder named by its id, which is what
/// the share sheet showed and what a saved or AirDropped file was called. This gives it the
/// day it was taken and its place in the entry instead ("DumpNotes 2026-09-23 3.jpg"), by
/// linking the file under that name in a temporary folder: no copy, no extra space.
enum ShareableMedia {
    static func url(for item: MediaItem, index: Int, fileStore: MediaFileStore) -> URL {
        let source = fileStore.url(for: item.relativePath)
        let day = item.draft?.entryDateKey ?? ""
        let name = "DumpNotes \(day) \(index + 1).\(source.pathExtension)"
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Share/\(item.id.uuidString)", isDirectory: true)
        let target = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.linkItem(at: source, to: target)
            return target
        } catch {
            return source
        }
    }
}
