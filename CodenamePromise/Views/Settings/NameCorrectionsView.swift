import CodenamePromiseCore
import SwiftUI

/// Teaching the app how to spell the names in your life.
///
/// Speech-to-text will never learn that your Lizzy is a Lizzy. It picks whichever spelling is
/// commoner in its training data and produces that one in every entry, forever. Without this
/// the only remedy is retyping someone's name every time you mention them, which is both
/// tedious and the sort of thing that makes a journal feel like it is not quite yours.
struct NameCorrectionsView: View {
    let store: DraftStore

    @State private var corrections = NameCorrectionStore().load()
    @State private var heard = ""
    @State private var meant = ""
    @State private var fixReport: FixReport?

    @FocusState private var focusedField: Field?

    private enum Field { case heard, meant }

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    TextField("Lizzie", text: $heard)
                        .focused($focusedField, equals: .heard)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .meant }
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    TextField("Lizzy", text: $meant)
                        .focused($focusedField, equals: .meant)
                        .submitLabel(.done)
                        .onSubmit(add)
                    Button(action: add) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(canAdd ? Brand.violet : Color.secondary.opacity(0.4))
                    .disabled(!canAdd)
                }
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
            } header: {
                Text("What it hears, what you meant")
            } footer: {
                Text("Applied to new recordings as they come back. Whole words only, so a name inside a longer word is left alone.")
            }

            if corrections.isEmpty {
                Section {
                    Text("Nothing to correct yet. Add the names it keeps getting wrong.")
                        .font(Type.body(15))
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Corrections") {
                    ForEach(corrections.corrections) { correction in
                        HStack {
                            Text(correction.heard).foregroundStyle(.secondary)
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(correction.meant).fontWeight(.medium)
                        }
                    }
                    .onDelete(perform: delete)
                }

                Section {
                    Button(action: fixExisting) {
                        Label("Fix entries you already have", systemImage: "wand.and.sparkles")
                    }
                    if let fixReport {
                        Text(fixReport.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    // Said out loud because it edits words already written down, which
                    // nothing else in this app does without being asked twice.
                    Text("Rewrites past entries where these names appear. Your recordings are untouched.")
                }
            }
        }
        .navigationTitle("Names")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var canAdd: Bool {
        NameCorrection(heard: heard, meant: meant).isUsable
    }

    private func add() {
        guard canAdd else { return }
        corrections = NameCorrectionStore().add(heard: heard, meant: meant)
        heard = ""
        meant = ""
        focusedField = .heard
        fixReport = nil
        Haptics.landed()
    }

    private func delete(at offsets: IndexSet) {
        let store = NameCorrectionStore()
        for index in offsets {
            corrections = store.remove(corrections.corrections[index].id)
        }
        fixReport = nil
    }

    /// Applies the corrections to entries already written.
    ///
    /// Reports what it did rather than doing it silently: this is the one action in the app
    /// that edits words that are already in the journal, and somebody should be able to see
    /// that it touched three entries and not thirty.
    private func fixExisting() {
        guard !corrections.isEmpty else { return }
        do {
            var entries = 0
            var names = 0
            for draft in try store.allDrafts() {
                let original = draft.content.rawText
                let matches = corrections.matchCount(in: original)
                guard matches > 0 else { continue }
                try store.updateRawText(corrections.apply(to: original), for: draft)
                entries += 1
                names += matches
            }
            fixReport = FixReport(entries: entries, names: names)
            Haptics.landed()
        } catch {
            fixReport = FixReport(error: error.localizedDescription)
        }
    }

    private struct FixReport {
        var entries = 0
        var names = 0
        var error: String?

        var message: String {
            if let error { return error }
            if entries == 0 { return "Nothing to change. These names don't appear in any entry." }
            let nameWord = names == 1 ? "mention" : "mentions"
            let entryWord = entries == 1 ? "entry" : "entries"
            return "Corrected \(names) \(nameWord) across \(entries) \(entryWord)."
        }
    }
}
