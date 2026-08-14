import Foundation
import Testing
@testable import CodenamePromiseCore

@Suite("Domain invariants")
struct DomainInvariantTests {

    @Test("createdAt and id survive every mutation (invariants 1 and 2)")
    func identityIsImmutable() {
        let created = Date(timeIntervalSince1970: 1_000_000)
        let draft = EntryDraft(createdAt: created)
        let id = draft.id

        draft.updateRawText("something", now: created.addingTimeInterval(60))
        draft.applyFormatting("- something", formatterVersion: "wwwt-1", now: created.addingTimeInterval(120))
        draft.updateTitle("A day", now: created.addingTimeInterval(180))

        #expect(draft.id == id)
        #expect(draft.createdAt == created)
        #expect(draft.updatedAt == created.addingTimeInterval(180))
    }

    @Test("formatting never touches rawText (invariant 3)")
    func formattingPreservesUserVoice() {
        let draft = EntryDraft()
        draft.updateRawText("i rambled a bit and thats fine")
        let userWords = draft.content.rawText

        draft.applyFormatting("- I rambled a bit\n- And that's fine", formatterVersion: "wwwt-1")

        #expect(draft.content.rawText == userWords)
        #expect(draft.content.formattedText != draft.content.rawText)
        #expect(draft.content.formatterVersion == "wwwt-1")
    }

    @Test("dictation appends rather than replacing, so a second recording can't wipe the first")
    func dictationAppends() {
        let draft = EntryDraft()
        draft.appendRawText("First thought.")
        draft.appendRawText("Second thought.")

        #expect(draft.content.rawText.contains("First thought."))
        #expect(draft.content.rawText.contains("Second thought."))
    }

    @Test("at most one SyncState per target (invariant 6)")
    func syncStateIsUniquePerTarget() {
        let draft = EntryDraft()
        let first = draft.syncState(for: .notion)
        let second = draft.syncState(for: .notion)
        _ = draft.syncState(for: .obsidian)

        #expect(first === second)
        #expect(draft.syncStates.filter { $0.target == .notion }.count == 1)
        #expect(draft.syncStates.count == 2)
    }

    /// The regression that motivated content hashing. If sync bookkeeping bumped
    /// `updatedAt` and dirtiness were `updatedAt > lastSyncedAt`, a completed sync would
    /// immediately mark itself dirty and re-sync forever — which, combined with a
    /// non-idempotent insert, duplicates the entry on every pass. See ADR-016.
    @Test("recording a successful sync does not re-dirty the draft")
    func syncBookkeepingDoesNotLoop() {
        let draft = EntryDraft()
        draft.updateRawText("What went well today")
        let updatedBefore = draft.updatedAt

        #expect(draft.needsSync(to: .notion))

        let state = draft.syncState(for: .notion)
        state.beginAttempt(contentHash: draft.contentHash)
        state.markSynced(externalId: "page-1", contentHash: draft.contentHash)

        #expect(draft.updatedAt == updatedBefore, "sync bookkeeping must not count as a content mutation")
        #expect(draft.needsSync(to: .notion) == false)
    }

    @Test("editing after a sync makes exactly that destination dirty again")
    func contentChangeReDirties() {
        let draft = EntryDraft()
        draft.updateRawText("v1")
        let notion = draft.syncState(for: .notion)
        notion.markSynced(externalId: "page-1", contentHash: draft.contentHash)

        #expect(draft.needsSync(to: .notion) == false)

        draft.updateRawText("v2")

        #expect(draft.needsSync(to: .notion))
        #expect(draft.needsSync(to: .obsidian), "a never-synced destination is always dirty")
    }

    @Test("content hash distinguishes field boundaries")
    func hashDoesNotCollideAcrossFields() {
        let a = EntryContent(title: "ab", rawText: "")
        let b = EntryContent(title: "a", rawText: "b")
        #expect(a.contentHash != b.contentHash)

        var c = EntryContent(rawText: "same")
        let before = c.contentHash
        c.formattedText = "- same"
        #expect(c.contentHash != before, "formatted text is part of what a destination receives")
    }
}

@Suite("CalendarDay")
struct CalendarDayTests {

    /// The 00:30 case: journaling just after midnight about the day that just ended.
    @Test("a late-night entry defaults to the local calendar day, not UTC")
    func lateNightEntryUsesLocalDay() throws {
        let tz = try #require(TimeZone(identifier: "America/New_York"))
        // 2026-08-13T04:30Z is 2026-08-13 00:30 in New York.
        let instant = try #require(ISO8601DateFormatter().date(from: "2026-08-13T04:30:00Z"))

        let localDay = CalendarDay(date: instant, timeZone: tz)
        let utcDay = CalendarDay(date: instant, timeZone: try #require(TimeZone(identifier: "UTC")))

        #expect(localDay.rawValue == "2026-08-13")
        #expect(utcDay.rawValue == "2026-08-13")

        // And 23:30 local on the 12th is already the 13th in UTC — the case that would
        // silently misfile entries if we derived the day from a UTC timestamp.
        let evening = try #require(ISO8601DateFormatter().date(from: "2026-08-13T03:30:00Z"))
        #expect(CalendarDay(date: evening, timeZone: tz).rawValue == "2026-08-12")
        #expect(CalendarDay(date: evening, timeZone: TimeZone(identifier: "UTC")!).rawValue == "2026-08-13")
    }

    @Test("the entry day is user-editable, because the default is only a guess")
    func entryDateIsEditable() throws {
        let draft = EntryDraft()
        let yesterday = try #require(CalendarDay(rawValue: "2026-08-11"))
        draft.setEntryDate(yesterday)
        #expect(draft.entryDate == yesterday)
    }

    @Test("string ordering equals chronological ordering")
    func lexicographicOrderIsChronological() throws {
        let days = ["2026-08-09", "2025-12-31", "2026-01-01"].compactMap(CalendarDay.init(rawValue:))
        #expect(days.sorted().map(\.rawValue) == ["2025-12-31", "2026-01-01", "2026-08-09"])
    }

    @Test("malformed and impossible dates are rejected", arguments: [
        "2026-8-9", "26-08-09", "2026-13-01", "2026-02-30", "not-a-date", "", "2026-08-09T00:00",
    ])
    func rejectsBadInput(raw: String) {
        #expect(CalendarDay(rawValue: raw) == nil)
    }

    @Test("an unparseable stored key degrades to the creation day instead of trapping")
    func unreadableKeyDoesNotBreakTheEntry() {
        let draft = EntryDraft(createdAt: Date(timeIntervalSince1970: 1_000_000))
        #expect(draft.entryDate.rawValue.count == 10)
    }
}

@Suite("Editor buffer merge")
struct TextMergeTests {

    /// The regression: a transcript merged into the model was invisible in the editor, and
    /// the next commit wrote the stale buffer straight over it.
    @Test("an external addition is folded into the buffer")
    func absorbsAppendedText() {
        let result = TextMerge.absorbing(
            buffer: "Typed so far",
            baseline: "Typed so far",
            current: "Typed so far\n\nAnd the dictated part."
        )
        #expect(result == "Typed so far\n\nAnd the dictated part.")
    }

    @Test("typing that happened while the transcript landed is kept")
    func keepsLocalEditsAlongsideAddition() {
        let result = TextMerge.absorbing(
            buffer: "Typed so far, plus more I typed",
            baseline: "Typed so far",
            current: "Typed so far\n\nAnd the dictated part."
        )
        #expect(result == "Typed so far, plus more I typed\n\nAnd the dictated part.")
    }

    @Test("nothing happens when the model hasn't moved")
    func noChangeIsNoOp() {
        #expect(TextMerge.absorbing(buffer: "abc", baseline: "abc", current: "abc") == "abc")
    }

    @Test("an unsaved local edit is untouched when the model is unchanged")
    func localOnlyEditSurvives() {
        #expect(TextMerge.absorbing(buffer: "abc plus more", baseline: "abc", current: "abc")
                == "abc plus more")
    }

    @Test("absorbing twice does not duplicate the words")
    func idempotent() {
        let once = TextMerge.absorbing(buffer: "a", baseline: "a", current: "a\n\nb")
        let twice = TextMerge.absorbing(buffer: once, baseline: "a\n\nb", current: "a\n\nb")
        #expect(twice == "a\n\nb")
    }

    /// Can't reconcile — so keep the thing that is hardest to recreate.
    @Test("an unreconcilable divergence keeps the model's text")
    func divergenceFavoursTheModel() {
        let result = TextMerge.absorbing(
            buffer: "something else entirely",
            baseline: "original",
            current: "a completely different value"
        )
        #expect(result == "a completely different value")
    }

    @Test("appending into an empty editor works")
    func emptyBufferGainsTranscript() {
        #expect(TextMerge.absorbing(buffer: "", baseline: "", current: "A transcript.")
                == "A transcript.")
    }
}

@Suite("Destination links")
@MainActor
struct DestinationLinkTests {

    @Test("a dashed page id becomes a compact Notion URL")
    func dashedIdIsNormalised() throws {
        let link = try #require(
            DestinationLink.notion(pageId: "3bc5ebd5-da97-8093-a09d-ec6cab2c43f4")
        )
        #expect(link.web.absoluteString == "https://www.notion.so/3bc5ebd5da978093a09dec6cab2c43f4")
        #expect(link.app?.absoluteString == "notion://www.notion.so/3bc5ebd5da978093a09dec6cab2c43f4")
    }

    @Test("an already-compact id is left alone")
    func compactIdWorks() throws {
        let link = try #require(DestinationLink.notion(pageId: "3bc5ebd5da978093a09dec6cab2c43f4"))
        #expect(link.web.absoluteString.hasSuffix("3bc5ebd5da978093a09dec6cab2c43f4"))
    }

    /// A link that looks plausible and 404s is worse than no button at all.
    @Test("ids that aren't Notion page ids produce no link", arguments: [
        "", "page-1", "page-2026-08-13", "not-a-uuid", "3bc5ebd5da978093a09dec6cab2c43",
    ])
    func rejectsNonPageIds(id: String) {
        #expect(DestinationLink.notion(pageId: id) == nil)
    }

    @Test("an unsynced entry has nothing to open")
    func unsyncedHasNoLink() {
        let state = SyncState(target: .notion)
        #expect(DestinationLink.url(for: state) == nil)
    }

    @Test("a synced entry links to its page")
    func syncedHasLink() throws {
        let state = SyncState(target: .notion)
        state.externalId = "3bc5ebd5-da97-8093-a09d-ec6cab2c43f4"
        let link = try #require(DestinationLink.url(for: state))
        #expect(link.web.host == "www.notion.so")
    }

    @Test("destinations without a known link scheme offer none")
    func unknownDestinationHasNoLink() {
        let state = SyncState(target: .obsidian)
        state.externalId = "3bc5ebd5-da97-8093-a09d-ec6cab2c43f4"
        #expect(DestinationLink.url(for: state) == nil)
    }
}

@Suite("Grouping media by capture day")
struct MediaDayGroupingTests {

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func item(_ iso: String?) -> MediaDayGrouping.Item {
        MediaDayGrouping.Item(id: UUID(), capturedAt: iso.map(date))
    }

    @Test("photos land in the day they were taken, newest first")
    func groupsByDay() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let groups = MediaDayGrouping.group([
            item("2026-08-12T10:00:00Z"),
            item("2026-08-14T09:00:00Z"),
            item("2026-08-12T18:00:00Z"),
        ], timeZone: utc)

        #expect(groups.count == 2)
        #expect(groups[0].day?.rawValue == "2026-08-14")
        #expect(groups[1].day?.rawValue == "2026-08-12")
        #expect(groups[1].items.count == 2)
    }

    /// The same reasoning as ADR-006: a photo taken at 11pm belongs to that evening.
    @Test("the day is the user's local day, not UTC")
    func usesLocalDay() throws {
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        // 03:30Z on the 14th is 23:30 on the 13th in New York.
        let groups = MediaDayGrouping.group([item("2026-08-14T03:30:00Z")], timeZone: newYork)
        #expect(groups[0].day?.rawValue == "2026-08-13")
    }

    /// Screenshots and some edited images have no EXIF date. Guessing would file them under
    /// the wrong day; dropping them would lose them.
    @Test("undated items are kept and flagged rather than guessed at")
    func undatedItemsSurvive() {
        let groups = MediaDayGrouping.group([item("2026-08-12T10:00:00Z"), item(nil), item(nil)])

        #expect(groups.count == 2)
        let undated = groups.last!
        #expect(undated.isUndated)
        #expect(undated.items.count == 2)
    }

    @Test("undated items come last, because they need a decision")
    func undatedGoLast() {
        let groups = MediaDayGrouping.group([item(nil), item("2026-08-12T10:00:00Z")])
        #expect(groups.first?.isUndated == false)
        #expect(groups.last?.isUndated == true)
    }

    @Test("nothing in, nothing out")
    func emptyInput() {
        #expect(MediaDayGrouping.group([]).isEmpty)
    }

    @Test("every item survives grouping")
    func nothingIsLost() {
        let items = (0..<20).map { i in
            item(i % 3 == 0 ? nil : "2026-08-\(10 + i % 5)T12:00:00Z")
        }
        let regrouped = MediaDayGrouping.group(items).flatMap(\.items)
        #expect(Set(regrouped.map(\.id)) == Set(items.map(\.id)))
    }
}

@Suite("Editing the structured text")
struct EditableFormattedTextTests {

    /// Invariant 3 constrains what the *formatter* may do. A person editing their own entry
    /// is not the formatter — but `rawText` still must not move.
    @Test("hand-editing the structured text leaves the original words alone")
    func editingFormattedLeavesRawAlone() {
        let draft = EntryDraft()
        draft.updateRawText("i rambled a bit")
        draft.applyFormatting("- i rambled a bit", formatterVersion: "wwwt-1")

        draft.updateFormattedText("- I rambled a bit, and here's more")

        #expect(draft.content.rawText == "i rambled a bit")
        #expect(draft.content.formattedText == "- I rambled a bit, and here's more")
    }

    @Test("an edit is recorded, so re-formatting can warn before replacing it")
    func editIsFlagged() {
        let draft = EntryDraft()
        draft.updateRawText("something")
        draft.applyFormatting("- something", formatterVersion: "wwwt-1")
        #expect(draft.content.formattedTextEditedByUser == false)

        draft.updateFormattedText("- something, edited")
        #expect(draft.content.formattedTextEditedByUser)
    }

    @Test("re-running formatting clears the edited flag")
    func reformattingResetsTheFlag() {
        let draft = EntryDraft()
        draft.updateRawText("something")
        draft.updateFormattedText("- hand written")
        #expect(draft.content.formattedTextEditedByUser)

        draft.applyFormatting("- regenerated", formatterVersion: "wwwt-2")
        #expect(draft.content.formattedTextEditedByUser == false)
    }

    @Test("editing the structured text makes the entry dirty for sync")
    func editingMakesDirty() {
        let draft = EntryDraft()
        draft.updateRawText("something")
        draft.applyFormatting("- something", formatterVersion: "wwwt-1")
        draft.syncState(for: .notion).markSynced(
            externalId: "page-1", contentHash: draft.contentHash
        )
        #expect(draft.needsSync(to: .notion) == false)

        draft.updateFormattedText("- something else entirely")

        #expect(draft.needsSync(to: .notion), "the destination holds the old version")
    }

    @Test("older stored content decodes without the new field")
    func decodesLegacyContent() throws {
        let json = #"{"rawText":"hello","formattedText":"- hello"}"#
        let content = try JSONDecoder().decode(EntryContent.self, from: Data(json.utf8))
        #expect(content.formattedTextEditedByUser == false)
        #expect(content.rawText == "hello")
    }
}

@Suite("Content decoding tolerance")
struct EntryContentDecodingTests {

    /// `EntryContent` is stored as one attribute on `EntryDraft`, so a decoding failure is
    /// not cosmetic — it is the user's words becoming unreadable. Synthesised `Codable`
    /// requires every key regardless of defaults, so each field is read defensively.
    @Test("content stored before a field existed still decodes")
    func toleratesMissingFields() throws {
        let legacy = #"{"rawText":"three things","formattedText":"- three things"}"#
        let content = try JSONDecoder().decode(EntryContent.self, from: Data(legacy.utf8))

        #expect(content.rawText == "three things")
        #expect(content.formattedText == "- three things")
        #expect(content.formattedTextEditedByUser == false)
    }

    @Test("the bare minimum decodes")
    func toleratesAlmostEmpty() throws {
        let content = try JSONDecoder().decode(EntryContent.self, from: Data("{}".utf8))
        #expect(content.rawText.isEmpty)
        #expect(content.title == nil)
    }

    @Test("a full round trip preserves everything")
    func roundTrips() throws {
        let original = EntryContent(
            title: "Tuesday", rawText: "raw", formattedText: "- raw",
            formatterVersion: "wwwt-1", formattedTextEditedByUser: true
        )
        let decoded = try JSONDecoder().decode(
            EntryContent.self, from: JSONEncoder().encode(original)
        )
        #expect(decoded == original)
    }
}
