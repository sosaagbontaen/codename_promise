import CodenamePromiseCore
import SwiftUI

/// Where you write: formatting you can see as you type, a toolbar for all of it above the
/// keyboard, and Markdown underneath.
///
/// Bound to the entry's Markdown, which it parses on the way in and writes on every change on
/// the way out; the controller's debounce decides when that reaches the store, exactly as it
/// did for the plain editor. After each edit the text is redrawn from the document, which is
/// what keeps markers, numbering and fonts consistent however the edit was made.
@available(iOS 26.0, *)
struct RichEditor: View {
    @Binding var markdown: String
    var focus: FocusState<Bool>.Binding

    @AppStorage(JournalFont.storageKey) private var journalFont: JournalFont = .sans
    @State private var text = AttributedString()
    @State private var selection = AttributedTextSelection()
    /// The Markdown this editor last wrote, to tell its own changes from someone else's.
    @State private var written: String?
    /// The text as last drawn, so redrawing doesn't trigger another redraw.
    @State private var drawn: AttributedString?
    /// The document the text held after the last edit, so an edit compares against it
    /// rather than reading the whole text a second time.
    @State private var current: RichDocument?
    @State private var addingLink = false
    @State private var linkAddress = ""

    private var look: RichText.Look { RichText.Look(font: journalFont) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // An invisible copy sets the height, so the page scrolls rather than the editor.
            Text(text + AttributedString("\n "))
                .lineSpacing(7)
                .padding(.vertical, 8)
                .padding(.horizontal, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hidden()
                .accessibilityHidden(true)
            TextEditor(text: $text, selection: $selection)
                .lineSpacing(7)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .focused(focus)
        }
        .frame(minHeight: 140)
        .onAppear { load(markdown) }
        .onChange(of: markdown) { _, now in
            if now != written { load(now) }
        }
        .onChange(of: journalFont) { _, _ in load(markdown) }
        .onChange(of: text) { old, new in edited(from: old, to: new) }
        .toolbar {
            ToolbarItem(placement: .keyboard) {
                FormattingBar(editor: self)
            }
        }
        .alert("Add a link", isPresented: $addingLink) {
            TextField("https://", text: $linkAddress)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Add") { applyLink() }
            Button("Remove link", role: .destructive) { setStyle { $0.link = nil } }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Loading and redrawing

    private func load(_ markdown: String) {
        let document = RichDocument(markdown: markdown)
        let rendered = RichText.attributed(document, look: look)
        written = markdown
        drawn = rendered
        current = document
        text = rendered
    }

    /// After any edit: read the text into a document and save it. Ordinary typing stops
    /// there; the text is only redrawn when the edit changed its structure (Return in a list,
    /// a marker backspaced into, numbering that needs updating).
    private func edited(from old: AttributedString, to new: AttributedString) {
        if let drawn, new == drawn { return }

        let previous = current ?? RichText.document(from: old)
        var document = RichText.document(from: new)
        var caret: RichText.Place?
        // Only a new line can be a Return, so the character-by-character check is skipped
        // for ordinary typing.
        if document.blocks.count == previous.blocks.count + 1,
           let line = insertedNewline(old: old, new: new) {
            caret = continueLine(at: line, previous: previous, document: &document)
        }
        keepFoldedContent(previous: previous, document: &document)
        current = document

        // Typing within lines that kept their kinds changes nothing drawn: no marker to
        // redraw, no number to update. That's nearly every keystroke, and skipping the
        // redraw is what keeps a long entry from lagging behind the keyboard.
        if caret == nil, Self.sameShape(previous, document) {
            save(document)
            return
        }

        let rendered = RichText.attributed(document, look: look)
        guard caret != nil || String(rendered.characters) != String(new.characters) else {
            save(document)
            return
        }
        let place = caret ?? currentPlace(in: new, document: document)
        // Not now: this runs while the text system is still committing the edit, and
        // replacing the text underneath it mid-commit crashes it. Next turn of the run loop
        // the edit is done; if more typing has landed by then, that edit is handled instead.
        DispatchQueue.main.async {
            guard text == new else { return }
            redraw(document, caret: place)
        }
    }

    /// Same lines, each the same kind at the same indent and folded the same way.
    private static func sameShape(_ a: RichDocument, _ b: RichDocument) -> Bool {
        guard a.blocks.count == b.blocks.count else { return false }
        return zip(a.blocks, b.blocks).allSatisfy {
            $0.kind == $1.kind && $0.indent == $1.indent && $0.folded == $1.folded
        }
    }

    private func save(_ document: RichDocument) {
        let markdown = document.markdown
        written = markdown
        if markdown != self.markdown { self.markdown = markdown }
    }

    private func redraw(_ document: RichDocument, caret: RichText.Place?, end: RichText.Place? = nil) {
        let rendered = RichText.attributed(document, look: look)
        drawn = rendered
        current = document
        if rendered != text { text = rendered }
        if let caret {
            let start = RichText.index(of: caret, in: rendered, document: document)
            if let end {
                let finish = RichText.index(of: end, in: rendered, document: document)
                selection = AttributedTextSelection(range: min(start, finish)..<max(start, finish))
            } else {
                // Type in the line's own text style, not the marker's.
                let line = min(caret.line, max(document.blocks.count - 1, 0))
                let typing = document.blocks.isEmpty ? nil : RichText.typingAttributes(for: document.blocks[line], look: look)
                selection = AttributedTextSelection(insertionPoint: start, typingAttributes: typing)
            }
        }
        save(document)
    }

    /// The line a single typed Return landed on, if that's what the edit was.
    private func insertedNewline(old: AttributedString, new: AttributedString) -> Int? {
        let before = Array(String(old.characters))
        let after = Array(String(new.characters))
        guard after.count == before.count + 1 else { return nil }
        var index = 0
        while index < before.count, before[index] == after[index] { index += 1 }
        guard after[index] == "\n", Array(after[(index + 1)...]) == Array(before[index...]) else { return nil }
        return after[..<index].filter { $0 == "\n" }.count
    }

    /// Return in a list continues it; Return on an empty item ends it; Return after a
    /// heading starts ordinary text. Returns where the caret should go.
    private func continueLine(at line: Int, previous: RichDocument, document: inout RichDocument) -> RichText.Place? {
        guard line < previous.blocks.count, line + 1 < document.blocks.count else { return nil }
        let was = previous.blocks[line]
        switch was.kind {
        case .bullet, .numbered, .check, .quote:
            if was.text.isEmpty {
                // An empty item: Return leaves the list, as in Notes.
                document.blocks[line].kind = .paragraph
                document.blocks[line].indent = 0
                document.blocks.remove(at: line + 1)
                return RichText.Place(line: line, offset: 0)
            }
            var kind = was.kind
            if case .check = kind { kind = .check(done: false) }
            document.blocks[line].kind = was.kind
            document.blocks[line].indent = was.indent
            document.blocks[line + 1].kind = kind
            document.blocks[line + 1].indent = was.indent
        case .heading:
            document.blocks[line].kind = was.kind
            document.blocks[line].folded = was.folded
            document.blocks[line + 1].kind = .paragraph
            document.blocks[line + 1].indent = 0
        case .paragraph:
            document.blocks[line + 1].indent = was.indent
        }
        return RichText.Place(line: line + 1, offset: 0)
    }

    /// Words folded under a toggle heading live on the heading's characters. If the heading
    /// is deleted those words would go with it, unseen; this puts them back at the end
    /// instead. Nothing someone wrote disappears because it happened to be folded.
    private func keepFoldedContent(previous: RichDocument, document: inout RichDocument) {
        let before = previous.blocks.compactMap(\.folded)
        let after = Set(document.blocks.compactMap(\.folded))
        for group in before where !after.contains(group) {
            document.blocks += group
        }
    }

    // MARK: - Selection

    private var selectedRanges: [Range<AttributedString.Index>] {
        switch selection.indices(in: text) {
        case .insertionPoint: return []
        case .ranges(let set): return set.ranges.filter { !$0.isEmpty }
        }
    }

    private func currentPlace(in text: AttributedString, document: RichDocument) -> RichText.Place {
        let index: AttributedString.Index
        switch selection.indices(in: text) {
        case .insertionPoint(let point): index = point
        case .ranges(let set): index = set.ranges.last?.upperBound ?? text.endIndex
        }
        return RichText.place(of: min(index, text.endIndex), in: text, document: document)
    }

    /// The lines the selection touches.
    private var selectedLines: ClosedRange<Int> {
        let document = RichText.document(from: text)
        let ranges = selectedRanges
        let start: AttributedString.Index
        let end: AttributedString.Index
        if let first = ranges.first, let last = ranges.last {
            start = first.lowerBound
            end = last.upperBound
        } else if case .insertionPoint(let point) = selection.indices(in: text) {
            start = point
            end = point
        } else {
            start = text.endIndex
            end = text.endIndex
        }
        let a = RichText.place(of: min(start, text.endIndex), in: text, document: document).line
        let b = RichText.place(of: min(end, text.endIndex), in: text, document: document).line
        return min(a, b)...max(a, b)
    }

    // MARK: - Inline formatting

    /// The style where the caret is, for showing which buttons are on.
    var styleHere: RichDocument.Style {
        selection.typingAttributes(in: text)[RichText.RunStyleKey.self] ?? RichDocument.Style()
    }

    var lineHere: RichDocument.Block? {
        let document = RichText.document(from: text)
        let line = selectedLines.lowerBound
        return line < document.blocks.count ? document.blocks[line] : nil
    }

    func toggle(_ keyPath: WritableKeyPath<RichDocument.Style, Bool>) {
        let ranges = selectedRanges
        let turnOn: Bool
        if ranges.isEmpty {
            turnOn = !styleHere[keyPath: keyPath]
        } else {
            turnOn = !ranges.allSatisfy { range in
                text[range].runs.allSatisfy { ($0[RichText.RunStyleKey.self] ?? .init())[keyPath: keyPath] }
            }
        }
        setStyle { $0[keyPath: keyPath] = turnOn }
    }

    /// Changes the style of the selection, or of what's typed next if nothing is selected.
    func setStyle(_ change: (inout RichDocument.Style) -> Void) {
        let ranges = selectedRanges
        if ranges.isEmpty {
            var typing = selection.typingAttributes(in: text)
            var style = typing[RichText.RunStyleKey.self] ?? RichDocument.Style()
            change(&style)
            typing[RichText.RunStyleKey.self] = style
            if case .insertionPoint(let point) = selection.indices(in: text) {
                selection = AttributedTextSelection(insertionPoint: point, typingAttributes: typing)
            }
            Haptics.picked()
            return
        }
        let document = RichText.document(from: text)
        let start = RichText.place(of: ranges.first!.lowerBound, in: text, document: document)
        let end = RichText.place(of: ranges.last!.upperBound, in: text, document: document)
        var updated = text
        for range in ranges {
            for run in updated[range].runs {
                var style = run[RichText.RunStyleKey.self] ?? RichDocument.Style()
                change(&style)
                updated[run.range][RichText.RunStyleKey.self] = style
            }
        }
        let next = RichText.document(from: updated)
        redraw(next, caret: start, end: end)
        Haptics.picked()
    }

    func promptForLink() {
        linkAddress = styleHere.link ?? ""
        addingLink = true
    }

    private func applyLink() {
        var address = linkAddress.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return }
        if !address.contains("://") { address = "https://" + address }
        setStyle { $0.link = address }
    }

    // MARK: - Line formatting

    /// Changes every line the selection touches, keeping the selection where it was.
    func changeLines(_ change: (inout RichDocument.Block) -> Void) {
        var document = RichText.document(from: text)
        let lines = selectedLines
        let caret = currentPlace(in: text, document: document)
        for line in lines where line < document.blocks.count {
            change(&document.blocks[line])
        }
        redraw(document, caret: caret)
        Haptics.picked()
    }

    /// Makes the lines `kind`, or plain text again if they all already are.
    func setKind(_ kind: RichDocument.Kind) {
        let document = RichText.document(from: text)
        let all = selectedLines.allSatisfy { line in
            line < document.blocks.count && Self.sameKind(document.blocks[line].kind, kind)
        }
        changeLines { block in
            if all {
                block.kind = .paragraph
                block.folded = nil
            } else {
                block.kind = kind
                if case .heading = kind { block.indent = 0 }
            }
        }
    }

    private static func sameKind(_ a: RichDocument.Kind, _ b: RichDocument.Kind) -> Bool {
        switch (a, b) {
        case (.check, .check): return true
        case let (.heading(l1, t1), .heading(l2, t2)): return l1 == l2 && t1 == t2
        default: return a == b
        }
    }

    func indent(_ by: Int) {
        changeLines { block in
            if case .heading = block.kind { return }
            block.indent = max(0, min(6, block.indent + by))
        }
    }

    func toggleChecked() {
        changeLines { block in
            if case .check(let done) = block.kind { block.kind = .check(done: !done) }
            else { block.kind = .check(done: false) }
        }
    }

    /// Folds or unfolds the toggle heading the caret is on.
    func toggleFold() {
        var document = RichText.document(from: text)
        let line = selectedLines.lowerBound
        guard line < document.blocks.count, case .heading(let level, true) = document.blocks[line].kind else { return }
        if let folded = document.blocks[line].folded {
            document.blocks[line].folded = nil
            document.blocks.insert(contentsOf: folded, at: line + 1)
        } else {
            var end = line + 1
            while end < document.blocks.count {
                if case .heading(let other, _) = document.blocks[end].kind, other <= level { break }
                end += 1
            }
            document.blocks[line].folded = Array(document.blocks[(line + 1)..<end])
            document.blocks.removeSubrange((line + 1)..<end)
        }
        redraw(document, caret: RichText.Place(line: line, offset: document.blocks[line].text.count))
        Haptics.picked()
    }
}

/// The formatting toolbar above the keyboard: every tool in one swipeable row, each showing
/// whether it's on where you're typing.
@available(iOS 26.0, *)
private struct FormattingBar: View {
    let editor: RichEditor

    private static let colors: [(String, String)] = [
        ("Red", "#e5534b"), ("Orange", "#e8853d"), ("Yellow", "#d4a72c"), ("Green", "#3fa35f"),
        ("Blue", "#3b82f6"), ("Purple", "#8f76ff"), ("Pink", "#e05a9c"), ("Gray", "#8b93a7"),
    ]
    private static let highlights: [(String, String)] = [
        ("Yellow", "#5c4a12"), ("Green", "#1f4a2e"), ("Blue", "#1f3456"), ("Pink", "#4f2236"), ("Purple", "#33295c"),
    ]

    var body: some View {
        let style = editor.styleHere
        let line = editor.lineHere
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                Menu {
                    Button("Heading 1") { editor.setKind(.heading(level: 1, toggle: false)) }
                    Button("Heading 2") { editor.setKind(.heading(level: 2, toggle: false)) }
                    Button("Heading 3") { editor.setKind(.heading(level: 3, toggle: false)) }
                    Divider()
                    Button("Toggle heading") { editor.setKind(.heading(level: 2, toggle: true)) }
                    Button("Plain text") { editor.changeLines { $0.kind = .paragraph; $0.folded = nil } }
                } label: {
                    tool("textformat.size", on: isHeading(line))
                }
                if case .heading(_, true) = line?.kind {
                    button(line?.folded == nil ? "chevron.down.circle" : "chevron.right.circle", "Fold or unfold") { editor.toggleFold() }
                }
                separator
                button("bold", "Bold", on: style.bold) { editor.toggle(\.bold) }
                button("italic", "Italic", on: style.italic) { editor.toggle(\.italic) }
                button("underline", "Underline", on: style.underline) { editor.toggle(\.underline) }
                button("strikethrough", "Strikethrough", on: style.strike) { editor.toggle(\.strike) }
                separator
                button("list.bullet", "Bulleted list", on: line?.kind == .bullet) { editor.setKind(.bullet) }
                button("list.number", "Numbered list", on: line?.kind == .numbered) { editor.setKind(.numbered) }
                button("checklist", "Checklist", on: isCheck(line)) { editor.toggleChecked() }
                button("text.quote", "Quote", on: line?.kind == .quote) { editor.setKind(.quote) }
                button("decrease.indent", "Outdent") { editor.indent(-1) }
                button("increase.indent", "Indent") { editor.indent(1) }
                separator
                button("link", "Link", on: style.link != nil) { editor.promptForLink() }
                Menu {
                    ForEach(Self.colors, id: \.1) { name, hex in
                        Button { editor.setStyle { $0.color = hex } } label: {
                            Label(name, systemImage: "circle.fill").tint(Color(hex: hex))
                        }
                    }
                    Button("Default colour") { editor.setStyle { $0.color = nil } }
                } label: {
                    tool("paintpalette", on: style.color != nil, tint: style.color.flatMap { Color(hex: $0) })
                }
                Menu {
                    ForEach(Self.highlights, id: \.1) { name, hex in
                        Button(name) { editor.setStyle { $0.highlight = hex } }
                    }
                    Button("No highlight") { editor.setStyle { $0.highlight = nil } }
                } label: {
                    tool("highlighter", on: style.highlight != nil)
                }
                Menu {
                    Button("Small") { editor.setStyle { $0.size = 0.85 } }
                    Button("Normal") { editor.setStyle { $0.size = nil } }
                    Button("Large") { editor.setStyle { $0.size = 1.25 } }
                    Button("Huge") { editor.setStyle { $0.size = 1.5 } }
                } label: {
                    tool("textformat", on: style.size != nil)
                }
            }
            .padding(.horizontal, 6)
        }
    }

    private var separator: some View {
        Rectangle().fill(Brand.muted.opacity(0.3)).frame(width: 1, height: 20).padding(.horizontal, 4)
    }

    private func isHeading(_ block: RichDocument.Block?) -> Bool {
        if case .heading = block?.kind { return true }
        return false
    }

    private func isCheck(_ block: RichDocument.Block?) -> Bool {
        if case .check = block?.kind { return true }
        return false
    }

    private func button(_ symbol: String, _ label: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { tool(symbol, on: on) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func tool(_ symbol: String, on: Bool, tint: Color? = nil) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(on ? (tint ?? Brand.violet) : Brand.ink)
            .frame(width: 38, height: 34)
            .background {
                if on { RoundedRectangle(cornerRadius: 8).fill(Brand.violet.opacity(0.18)) }
            }
    }
}
