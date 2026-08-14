import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A video chosen from the photo library, received as a file.
///
/// `PhotosPickerItem.loadTransferable(type: Data.self)` returns nil for most movies — they
/// are handed over as files, not bytes — so the previous `Data`-based path silently failed
/// for every video. This receives the file and copies it somewhere stable, because the URL
/// the system provides is only valid for the duration of the call.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked-\(UUID().uuidString).\(ext)")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}
