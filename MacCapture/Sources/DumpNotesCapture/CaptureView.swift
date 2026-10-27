import AppKit
import CodenamePromiseCore
import SwiftUI
import UniformTypeIdentifiers

/// The colors of the phone app, so the two read as one product.
private enum Brand {
    static let violet = Color(red: 0x8F / 255, green: 0x76 / 255, blue: 0xFF / 255)
    static let failed = Color(red: 0xF8 / 255, green: 0x71 / 255, blue: 0x71 / 255)
}

struct CaptureView: View {
    @Bindable var model: CaptureModel
    @State private var dropTargeted = false
    @State private var pasteMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(model.plan.days) { day in
                        DayCard(model: model, dayId: day.id, isOnly: model.plan.days.count == 1)
                    }
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 10) {
                Button {
                    model.addDay()
                } label: {
                    Label("Note for another day", systemImage: "plus")
                }
                Button("Add Files\u{2026}") { model.chooseFiles() }
                Spacer(minLength: 0)
            }
            .controlSize(.small)

            if let problem = model.problem {
                Text(problem).font(.callout).foregroundStyle(Brand.failed)
            }

            footer
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(minWidth: 420, minHeight: 380)
        .background(dropTargeted ? Brand.violet.opacity(0.08) : .clear)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Brand.violet, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(6)
            }
        }
        .onDrop(of: [.fileURL, .image, .movie], isTargeted: $dropTargeted) { providers in
            model.add(providers: providers)
            return true
        }
        .onAppear {
            // ⌘V with a file or an image on the pasteboard adds it as an attachment. Plain
            // text falls through to the note field.
            pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "v",
                   model.paste() {
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("DumpNotes")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Brand.violet)
            Spacer()
            if model.waiting > 0 {
                Text(model.waiting == 1 ? "1 waiting for your iPhone" : "\(model.waiting) waiting for your iPhone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("They\u{2019}re added to your journal the next time you open DumpNotes on your iPhone.")
            }
        }
    }

    private var footer: some View {
        HStack {
            if let added = model.justAdded {
                Label(added, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Brand.violet)
                    .font(.callout)
            } else {
                Text(model.plan.fileCount == 0
                     ? "Drop photos or videos anywhere, or paste a screenshot. They sort into the day they were taken."
                     : "Click a photo to look through them. Change a day\u{2019}s date to move everything in it.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                model.dump()
            } label: {
                if model.saving || model.reading > 0 {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Add").padding(.horizontal, 10)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.violet)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canAdd)
            .help("\u{2318}\u{21A9}")
        }
    }
}

/// One day: its date, which entry it goes to, its photos, and a note about it.
private struct DayCard: View {
    @Bindable var model: CaptureModel
    let dayId: UUID
    let isOnly: Bool

    var body: some View {
        if let day = model.plan[dayId] {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    DatePicker(
                        "Day",
                        selection: Binding(
                            get: { day.day.representativeDate() },
                            set: { model.setDay($0, for: dayId) }
                        ),
                        in: ...Date(),
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .fixedSize()

                    let existing = model.entries(on: day.day)
                    Picker("Entry", selection: Binding(
                        get: { day.entry.shown(among: existing) },
                        set: { model.plan[dayId]?.entry = $0 }
                    )) {
                        Text("New entry").tag(CapturePlan.EntryChoice.new)
                        if !existing.isEmpty {
                            Section("Existing entries") {
                                ForEach(existing) { entry in
                                    Text(entry.title).tag(CapturePlan.EntryChoice.existing(entry.id))
                                }
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)

                    Spacer(minLength: 0)

                    if !isOnly {
                        Button {
                            model.removeDay(dayId)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this day and everything in it")
                    }
                }
                .font(.callout)

                if !day.fileIds.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(day.fileIds, id: \.self) { fileId in
                                if let item = model.items[fileId] {
                                    Thumbnail(item: item) {
                                        model.preview(fileId)
                                    } onRemove: {
                                        model.remove(fileId)
                                    }
                                }
                            }
                        }
                        .padding(.top, 6)
                        .padding(.trailing, 6)
                    }
                }

                ZStack(alignment: .topLeading) {
                    NoteEditor(
                        text: Binding(
                            get: { model.plan[dayId]?.text ?? "" },
                            set: { model.plan[dayId]?.text = $0 }
                        ),
                        focusToken: model.focusDay == dayId ? model.focusRequest : nil
                    )
                    if day.text.isEmpty {
                        Text(isOnly && day.fileIds.isEmpty ? "What do you want to remember?" : "A note about this day")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: isOnly && day.fileIds.isEmpty ? 140 : 54)
            }
            .padding(10)
            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        }
    }
}

private struct Thumbnail: View {
    let item: CaptureModel.Item
    let onOpen: () -> Void
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onOpen) {
                Group {
                    if let image = item.thumbnail {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomLeading) {
                    if item.kind == .video {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.white)
                            .padding(4)
                            .shadow(radius: 2)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(item.url.lastPathComponent)\nClick to look through them")

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .help("Remove")
        }
    }
}

/// A plain text view that leaves file drops to the panel.
///
/// SwiftUI's `TextEditor` takes any drop that lands on it, and these cover most of the panel,
/// so dragging a photo in did nothing at all. This one only accepts dragged text.
private struct NoteEditor: NSViewRepresentable {
    @Binding var text: String
    /// Changes when this field should take focus; nil when another one should.
    let focusToken: Int?

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let view = TextOnlyDropTextView()
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator
        view.font = .systemFont(ofSize: 14)
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.textContainerInset = NSSize(width: 0, height: 0)
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView
        if view.string != text { view.string = text }
        if let focusToken, context.coordinator.lastFocus != focusToken {
            context.coordinator.lastFocus = focusToken
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var lastFocus = -1
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}

/// AppKit re-registers a text view's drag types whenever its settings change, so the
/// restriction lives in the type rather than in a one-off call.
private final class TextOnlyDropTextView: NSTextView {
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [.string] }
}
