import CodenamePromiseCore
import SwiftUI

/// Where you write: formatting you can see as you type, a toolbar for all of it above the
/// keyboard, and Markdown underneath.
///
/// Bound to the entry's Markdown, which it parses on the way in and writes on every change on
/// the way out; the controller's debounce decides when that reaches the store, exactly as it
/// did for the plain editor. After each edit the text is redrawn from the document, which is
/// what keeps markers, numbering and fonts consistent however the edit was made.
/// Where the first search match in an entry ends, for the page to scroll to.
enum SearchHit {
    static let id = "richEditor.searchHit"
}

@available(iOS 26.0, *)
struct RichEditor: View {
    @Binding var markdown: String
    var focus: FocusState<Bool>.Binding
    /// Words searched for, when the entry was opened from search. Their matches are
    /// highlighted for a moment by a copy drawn over the text: the entry itself isn't touched.
    var highlight: String? = nil

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
    /// The document last written out, so an edit that changes nothing (focusing the editor
    /// can nudge its attributes) doesn't rewrite the entry in normalised Markdown, bump its
    /// edit time and mark it as needing to sync again.
    @State private var saved: RichDocument?
    @State private var textJustChanged = false
    @State private var addingLink = false
    @State private var linkAddress = ""
    /// The text with every glyph clear except the search matches, which are dark on yellow,
    /// laid out exactly as the editor lays out the real text so they sit over the words.
    @State private var marks: AttributedString?
    /// The text up to the end of the first match, whose height is where that match is.
    @State private var throughFirstMatch: AttributedString?
    @State private var showingMarks = false

    private var look: RichText.Look { RichText.Look(font: journalFont) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // An invisible copy sets the height, so the page scrolls rather than the editor.
            Text(text)
                .lineSpacing(7)
                .padding(.top, 8)
                // A line's room below the last one, where the caret goes after Return.
                .padding(.bottom, 40)
                .padding(.horizontal, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hidden()
                .accessibilityHidden(true)
            if let throughFirstMatch {
                VStack(spacing: 0) {
                    Text(throughFirstMatch)
                        .lineSpacing(7)
                        .padding(.top, 8)
                        .padding(.horizontal, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .hidden()
                    Color.clear.frame(height: 1).id(SearchHit.id)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            TextEditor(text: $text, selection: $selection)
                .lineSpacing(7)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .focused(focus)
            if let marks {
                Text(marks)
                    .lineSpacing(7)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                    .padding(.horizontal, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(showingMarks ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 140)
        .onAppear {
            load(markdown)
            markMatches()
        }
        .onChange(of: markdown) { _, now in
            if now != written { load(now) }
        }
        .onChange(of: journalFont) { _, _ in load(markdown) }
        .onChange(of: text) { old, new in
            textJustChanged = true
            // Cleared after the selection handler below has had its turn, whichever order
            // SwiftUI runs the two in.
            DispatchQueue.main.async { DispatchQueue.main.async { textJustChanged = false } }
            edited(from: old, to: new)
        }
        .onChange(of: selection) { _, _ in
            // Next turn, once any edit in the same update has been seen: a caret that moved
            // because of typing is not a tap.
            DispatchQueue.main.async { if !textJustChanged { caretMoved() } }
        }
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

    // MARK: - Search matches

    /// Shades where the searched-for words start a word, the way search matches them, then
    /// fades the shading out.
    private func markMatches() {
        guard let highlight else { return }
        let terms = highlight.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let plain = String(text.characters)
        var found: [Range<String.Index>] = []
        for term in terms {
            var from = plain.startIndex
            while let match = plain.range(of: term, options: [.caseInsensitive, .diacriticInsensitive],
                                          range: from..<plain.endIndex) {
                let before = match.lowerBound == plain.startIndex ? nil : plain[plain.index(before: match.lowerBound)]
                if before.map({ !$0.isLetter && !$0.isNumber }) ?? true { found.append(match) }
                from = match.upperBound
            }
        }
        guard let first = found.min(by: { $0.lowerBound < $1.lowerBound }),
              let firstEnd = Range(first, in: text)?.upperBound else { return }

        var shaded = text
        shaded.foregroundColor = .clear
        // A link draws in the tint whatever its colour says.
        for (link, range) in shaded.runs[\.link] where link != nil { shaded[range].link = nil }
        for match in found {
            if let range = Range(match, in: shaded) {
                // The way Notes and Safari show a found word: legible in either appearance.
                shaded[range].backgroundColor = Color(red: 1, green: 0.84, blue: 0.2)
                shaded[range].foregroundColor = .black
            }
        }
        marks = shaded
        throughFirstMatch = AttributedString(text[..<firstEnd])
        showingMarks = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.6))
            withAnimation(.easeOut(duration: 0.9)) { showingMarks = false }
            try? await Task.sleep(for: .seconds(1))
            marks = nil
        }
    }

    // MARK: - Loading and redrawing

    private func load(_ markdown: String) {
        let document = RichDocument(markdown: markdown)
        let rendered = RichText.attributed(document, look: look)
        written = markdown
        drawn = rendered
        current = document
        saved = document
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
        // Before Return is handled, which may open a folded toggle on purpose.
        keepFoldedContent(previous: previous, document: &document)
        if document.blocks.count == previous.blocks.count + 1,
           let line = insertedNewline(old: old, new: new) {
            caret = continueLine(at: line, previous: previous, document: &document)
        } else if document.blocks.count == previous.blocks.count {
            caret = applyShortcut(previous: previous, document: &document)
        }
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
        // (Carrying the change onto newer text was tried: replacing the text while the
        // keyboard is partway through a word corrupts it, which is far worse than a line
        // that keeps its old style until the next structural edit.)
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
        if document == saved { return }
        saved = document
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
        case .heading(_, let toggle):
            document.blocks[line].kind = was.kind
            document.blocks[line + 1].kind = .paragraph
            document.blocks[line + 1].indent = 0
            if toggle, let folded = was.folded {
                // Return on a folded toggle opens it and starts a line inside, the way Notion
                // does, instead of a line after everything it holds.
                document.blocks[line].folded = nil
                document.blocks.insert(contentsOf: folded, at: line + 2)
            } else {
                document.blocks[line].folded = was.folded
            }
        case .paragraph:
            document.blocks[line + 1].indent = was.indent
        }
        return RichText.Place(line: line + 1, offset: 0)
    }

    /// Markdown typed at the start of a line becomes that kind of line as soon as its space
    /// is typed, the way Notion and Notes do it: "- " a bullet, "1. " a numbered item,
    /// "[] " a checkbox, "# " to "### " a heading, "> " a quote. Only on the space that
    /// completes the pattern, so text that merely starts that way is left alone.
    private static let shortcuts: [(pattern: String, kind: RichDocument.Kind)] = [
        ("### ", .heading(level: 3, toggle: false)), ("## ", .heading(level: 2, toggle: false)),
        ("# ", .heading(level: 1, toggle: false)), ("[ ] ", .check(done: false)), ("[] ", .check(done: false)),
        ("[x] ", .check(done: true)), ("- ", .bullet), ("* ", .bullet), ("> ", .quote),
    ]

    private func applyShortcut(previous: RichDocument, document: inout RichDocument) -> RichText.Place? {
        guard let line = previous.blocks.indices.first(where: { previous.blocks[$0] != document.blocks[$0] }) else { return nil }
        let before = previous.blocks[line], after = document.blocks[line]
        guard after.kind == .paragraph, before.kind == .paragraph else { return nil }
        let typed = after.text
        var matched: (length: Int, kind: RichDocument.Kind)?
        if let found = Self.shortcuts.first(where: { typed.hasPrefix($0.pattern) }) {
            matched = (found.pattern.count, found.kind)
        } else if let number = typed.firstMatch(of: #/^[0-9]{1,3}[.)] /#) {
            matched = (number.output.count, .numbered)
        }
        guard let matched else { return nil }
        // The space that finished the pattern is the character just typed.
        let spaceAt = typed.index(typed.startIndex, offsetBy: matched.length - 1)
        var withoutSpace = typed
        withoutSpace.remove(at: spaceAt)
        guard withoutSpace == before.text else { return nil }

        document.blocks[line].kind = matched.kind
        if case .heading = matched.kind { document.blocks[line].indent = 0 }
        document.blocks[line].runs = Self.dropping(matched.length, from: after.runs)
        return RichText.Place(line: line, offset: 0)
    }

    private static func dropping(_ count: Int, from runs: [RichDocument.Run]) -> [RichDocument.Run] {
        var remaining = count
        var out: [RichDocument.Run] = []
        for run in runs {
            if remaining >= run.text.count {
                remaining -= run.text.count
                continue
            }
            out.append(RichDocument.Run(String(run.text.dropFirst(remaining)), run.style))
            remaining = 0
        }
        return out
    }

    // MARK: - Tapping markers

    /// A caret placed on a line's marker: a checkbox ticks, a toggle's arrow folds or opens,
    /// and anything else puts the caret at the start of the words, so nothing gets typed in
    /// among the bullets and numbers.
    private func caretMoved() {
        guard case .insertionPoint(let point) = selection.indices(in: text),
              let document = current,
              let (line, start) = lineStart(containing: point),
              line < document.blocks.count
        else { return }
        let block = document.blocks[line]
        let length = lineLength(from: start)
        let lead = length - block.text.count
        let offset = text.characters.distance(from: start, to: point)
        guard lead > 0, offset < lead else { return }

        var updated = document
        switch block.kind {
        case .check(let done):
            updated.blocks[line].kind = .check(done: !done)
            Haptics.picked()
            redraw(updated, caret: RichText.Place(line: line, offset: block.text.count))
        case .heading(_, true):
            toggleFold(line: line)
        default:
            selection = AttributedTextSelection(insertionPoint: text.characters.index(start, offsetBy: lead))
        }
    }

    /// The line a position is on, and where that line starts.
    private func lineStart(containing point: AttributedString.Index) -> (Int, AttributedString.Index)? {
        var line = 0
        var start = text.startIndex
        var index = text.startIndex
        while index < point, index < text.endIndex {
            if text.characters[index] == "\n" {
                line += 1
                start = text.characters.index(after: index)
            }
            index = text.characters.index(after: index)
        }
        return (line, start)
    }

    private func lineLength(from start: AttributedString.Index) -> Int {
        var count = 0
        var index = start
        while index < text.endIndex, text.characters[index] != "\n" {
            count += 1
            index = text.characters.index(after: index)
        }
        return count
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
        let a = lineStart(containing: min(start, text.endIndex))?.0 ?? 0
        let b = lineStart(containing: min(end, text.endIndex))?.0 ?? a
        return min(a, b)...max(a, b)
    }

    // MARK: - Inline formatting

    /// The style where the caret is, for showing which buttons are on.
    var styleHere: RichDocument.Style {
        selection.typingAttributes(in: text)[RichText.RunStyleKey.self] ?? RichDocument.Style()
    }

    /// The line the caret is on, from the document the editor already holds. The toolbar
    /// asks on every keystroke, so this counts lines rather than re-reading the entry.
    var lineHere: RichDocument.Block? {
        guard let document = current else { return nil }
        let point: AttributedString.Index
        switch selection.indices(in: text) {
        case .insertionPoint(let at): point = at
        case .ranges(let set): point = set.ranges.first?.lowerBound ?? text.endIndex
        }
        guard let (line, _) = lineStart(containing: min(point, text.endIndex)) else { return nil }
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

    /// Turns the "/" line into `kind`, empty and ready to type in.
    func replaceSlash(with kind: RichDocument.Kind) {
        guard var document = current else { return }
        let line = selectedLines.lowerBound
        guard line < document.blocks.count, document.blocks[line].text == "/" else { return }
        document.blocks[line].runs = []
        document.blocks[line].kind = kind
        if case .heading = kind { document.blocks[line].indent = 0 }
        redraw(document, caret: RichText.Place(line: line, offset: 0))
        Haptics.picked()
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
        toggleFold(line: selectedLines.lowerBound)
    }

    private func toggleFold(line: Int) {
        var document = current ?? RichText.document(from: text)
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
        if line?.text == "/" {
            blockPicker
        } else {
            tools(style: style, line: line)
        }
    }

    /// Notion's slash menu, in the toolbar: "/" alone on a line offers what the line can
    /// become, and picking one replaces the slash.
    private var blockPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                pick("Heading 1", "textformat.size.larger", .heading(level: 1, toggle: false))
                pick("Heading 2", "textformat.size", .heading(level: 2, toggle: false))
                pick("Heading 3", "textformat.size.smaller", .heading(level: 3, toggle: false))
                pick("Toggle", "chevron.right.circle", .heading(level: 2, toggle: true))
                pick("Checklist", "checklist", .check(done: false))
                pick("Bullets", "list.bullet", .bullet)
                pick("Numbers", "list.number", .numbered)
                pick("Quote", "text.quote", .quote)
            }
            .padding(.horizontal, 8)
        }
    }

    private func pick(_ title: String, _ symbol: String, _ kind: RichDocument.Kind) -> some View {
        Button {
            editor.replaceSlash(with: kind)
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Brand.violet.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Brand.ink)
    }

    private func tools(style: RichDocument.Style, line: RichDocument.Block?) -> some View {
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
