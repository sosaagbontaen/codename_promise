import CodenamePromiseCore
import SwiftUI

/// Where an entry can go, with the app-agnostic answer first.
///
/// This replaced a full-width "Send to Notion" that was the largest and brightest control in
/// the editor. Two things were wrong with it. It named one company in the primary action of a
/// journalling app, and more importantly it implied the entry was not finished until it had
/// been pushed somewhere. In a local-first app that is backwards: the entry was saved before
/// the sentence was finished, and there is nothing to submit.
///
/// So sending moved into a sheet you open when you want it, and the order inside says what
/// the app believes. Sharing as text is first because it works with every notes app anyone
/// actually uses, needs no account, and cannot break. Notion is second, listed as one
/// destination rather than as the destination, and only appears once somebody has connected
/// it.
struct SendSheet: View {
    let markdown: String
    let subject: String
    /// Nil when no destination is configured, which is how the app ships and what most
    /// people will always see.
    let notion: Notion?

    @Environment(\.dismiss) private var dismiss

    /// Everything the Notion rows need, so this sheet knows nothing about sync internals.
    struct Notion {
        let actionTitle: String
        let canSend: Bool
        let isSending: Bool
        let send: () -> Void
        let chooseExistingPage: () -> Void
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // The preview is what names the entry in the system sheet's header.
                    // Without it a shared string shows a blank placeholder tile, which
                    // reads as the app having nothing to hand over.
                    ShareLink(
                        item: markdown,
                        subject: Text(subject),
                        preview: SharePreview(subject, image: Image(systemName: "text.book.closed"))
                    ) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("Any app")
                } footer: {
                    // Names the apps, because "share" alone does not tell someone that the
                    // notes app they already use is on the other side of it.
                    Text("Opens the share sheet with this entry as markdown, with each section\u{2019}s heading in bold. Works with Notes, Bear, Obsidian, Drafts, Files and anything else that takes text.")
                }

                if let notion {
                    Section {
                        Button {
                            notion.send()
                            dismiss()
                        } label: {
                            HStack {
                                Label(notion.actionTitle, systemImage: "arrow.up.forward.square")
                                Spacer()
                                if notion.isSending { ProgressView().controlSize(.small) }
                            }
                        }
                        .disabled(!notion.canSend || notion.isSending)

                        Button {
                            notion.chooseExistingPage()
                            dismiss()
                        } label: {
                            Label("Add to an existing page", systemImage: "text.append")
                        }
                    } header: {
                        Text("Notion")
                    } footer: {
                        Text("Optional. Your entry stays on this phone either way.")
                    }
                }
            }
            .navigationTitle("Send")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
