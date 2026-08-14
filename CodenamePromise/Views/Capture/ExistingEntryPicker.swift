import CodenamePromiseCore
import SwiftUI

/// Choose an entry already in Notion to add to.
///
/// This lists pages but never opens one. Appending doesn't need to read the existing content,
/// and not reading it is the point: a page can hold toggles, callouts and embeds that this app
/// has no way to represent, and anything it pulled in it would eventually have to write back
/// flattened. Adding to the end touches none of that.
struct ExistingEntryPicker: View {
    let service: any NotionConnectionService
    let onPick: (NotionPage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pages: [NotionPage] = []
    @State private var isLoading = true
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if let failure {
                    ContentUnavailableView("Couldn't load your entries",
                                           systemImage: "exclamationmark.triangle",
                                           description: Text(failure))
                } else if pages.isEmpty {
                    ContentUnavailableView("No entries yet",
                                           systemImage: "doc.text",
                                           description: Text("There's nothing in the connected database to add to."))
                } else {
                    List(pages) { page in
                        Button {
                            onPick(page)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(page.title).foregroundStyle(.primary)
                                if let date = page.entryDate {
                                    Text(date).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to an entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            pages = try await service.pages()
            failure = nil
        } catch let error as APIError {
            failure = error.userFacingMessage
        } catch {
            failure = error.localizedDescription
        }
    }
}
