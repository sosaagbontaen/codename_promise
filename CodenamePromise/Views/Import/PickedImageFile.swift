import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A photo chosen from the library, received as a file rather than as bytes.
///
/// The old import asked for `Data`, which put every photo's full contents in memory, then
/// decoded the whole image a second time to make a 56-point thumbnail, then wrote it out
/// with a `.jpg` extension whatever it actually was — so an iPhone's HEIC arrived labelled
/// as a JPEG. Receiving the file keeps its real format and never holds it in memory.
///
/// The URL the system hands over is only valid inside the closure, so it is copied out
/// before returning, same as `PickedMovie`.
struct PickedImageFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let ext = received.file.pathExtension.isEmpty ? "jpg" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked-\(UUID().uuidString).\(ext)")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedImageFile(url: copy)
        }
    }
}
