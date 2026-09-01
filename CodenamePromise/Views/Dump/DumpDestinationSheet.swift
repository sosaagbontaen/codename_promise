import CodenamePromiseCore
import SwiftUI

/// Where this dump lands.
///
/// Two answers, and the app has always supported both — a new page of its own, or appended to
/// a page that already exists. The second is what the concept had no way to know about, and
/// it is the one people reach for when a day already has an entry they want to add to.
///
/// Deliberately per-dump rather than a setting: which of those you want changes constantly,
/// and burying it in Settings would mean going and finding the entry again afterwards.
struct DumpDestinationSheet: View {
    let connection: NotionConnectionStatus?
    @Binding var appendTo: NotionPage?
    let connectionService: (any NotionConnectionService)?

    @Environment(\.dismiss) private var dismiss
    @State private var pages: [NotionPage] = []
    @State private var phase: Phase = .idle

    enum Phase: Equatable { case idle, loading, failed(String) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        appendTo = nil
                        dismiss()
                    } label: {
                        row(
                            icon: "doc.badge.plus",
                            title: "A new page",
                            detail: connection?.databaseTitle.map { "In \($0)" }
                                ?? "In your Notion database",
                            selected: appendTo == nil
                        )
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text("Each dump becomes its own page, which is what makes them easy to find later.")
                }

                Section {
                    switch phase {
                    case .loading:
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Reading your Notion pages\u{2026}")
                                .font(Type.caption(13))
                                .foregroundStyle(Brand.muted)
                        }
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(Type.caption(13))
                            .foregroundStyle(Brand.failed)
                    case .idle where pages.isEmpty:
                        Text("No pages found in that database yet.")
                            .font(Type.caption(13))
                            .foregroundStyle(Brand.muted)
                    case .idle:
                        ForEach(pages) { page in
                            Button {
                                appendTo = page
                                dismiss()
                            } label: {
                                row(
                                    icon: "text.append",
                                    title: page.title,
                                    detail: page.entryDate ?? "Existing page",
                                    selected: appendTo?.id == page.id
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("Or add to an existing page")
                } footer: {
                    Text("Appends to the end. Only the blocks this app wrote are ever replaced \u{2014} the rest of that page is left alone.")
                }
            }
            .navigationTitle("Where it goes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func row(icon: String, title: String, detail: String, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(selected ? Brand.violet : Brand.muted)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Type.label(15.5, .semibold)).lineLimit(1)
                Text(detail).font(Type.caption(12)).foregroundStyle(Brand.muted).lineLimit(1)
            }
            Spacer(minLength: 6)
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Brand.violet)
            }
        }
        .contentShape(Rectangle())
    }

    private func load() async {
        guard let connectionService, connection?.ready == true else { return }
        phase = .loading
        do {
            pages = try await connectionService.pages()
            phase = .idle
        } catch {
            phase = .failed((error as? APIError)?.userFacingMessage
                            ?? "Couldn't read your Notion pages.")
        }
    }
}
