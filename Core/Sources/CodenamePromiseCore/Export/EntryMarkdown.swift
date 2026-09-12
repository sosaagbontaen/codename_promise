import Foundation

/// One entry as markdown somebody would actually want to paste somewhere.
///
/// Deliberately not `JournalExporter.markdown`, which is a different job. That one writes an
/// archive: YAML front matter carrying the entry's id so a re-import can match it, and
/// relative links into a media folder that travels with the file. Correct for a backup, and
/// noise in a note. Pasted into Bear or Apple Notes it opens with six lines of metadata and
/// then links to images that are not there.
///
/// This is the other half of "works with the notes app you already use". Notion needs an API
/// because it is a database with a block model. Almost nothing else does: Obsidian, Bear,
/// Craft, Apple Notes, Day One and Drafts all take markdown from the share sheet. So the
/// integration surface for most of that list is this function plus a share sheet, with no
/// OAuth, no server, no review process, and nothing that stops working offline.
public enum EntryMarkdown {

    /// - Parameters:
    ///   - organised: preferred when present, because the sections are the thing the app
    ///     made and the reason someone would send this anywhere.
    ///   - text: what the person said or wrote, used when there is nothing organised yet.
    public static func render(
        title: String?,
        day: CalendarDay,
        organised: OrganisedEntry?,
        text: String
    ) -> String {
        var out = "# \(heading(title: title, day: day))\n"

        // The date always appears, even when it is also the heading, because a note pasted
        // into another app loses every bit of context this one had around it.
        out += "\n*\(day.representativeDate().formatted(.dateTime.weekday(.wide).month(.wide).day().year()))*\n"

        let body = Self.body(organised: organised, formatted: nil, raw: text).trimmed()
        if !body.isEmpty { out += "\n\(body)\n" }

        return out
    }

    /// The body of an entry, in the order of what it actually is.
    ///
    /// One function because two callers were choosing separately and drifting: sharing
    /// preferred the arranged version while syncing to Notion never looked at it, so the
    /// same entry left the app as two different documents depending on which button you
    /// pressed.
    ///
    /// Headings are bold rather than `##`.
    ///
    /// A heading block is heavier than a journal section wants: in Notion an `##` becomes a
    /// structural heading with its own weight and collapse behaviour, which suits a document
    /// and overstates a paragraph about somebody's afternoon. Bold marks the same boundary
    /// without turning three thoughts into three chapters.
    ///
    /// The backend parses `**` into a bold annotation, so this arrives as emphasis rather
    /// than as characters. Anywhere that does not read markdown shows the asterisks, which
    /// is true of `##` as well and is the cost of one format for every destination.
    public static func body(
        organised: OrganisedEntry?,
        formatted: String?,
        raw: String
    ) -> String {
        if let organised, !organised.isEmpty {
            return organised.sections
                .map { "**\($0.heading)**\n\n\($0.body.trimmed())" }
                .joined(separator: "\n\n")
        }
        if let formatted, !formatted.trimmed().isEmpty { return formatted }
        return raw
    }

    /// The entry's own name, or the day it is about.
    ///
    /// Never "Untitled". An untitled entry is usually the one someone dictated and has not
    /// named, which is the normal case here rather than a defect, and a note called Untitled
    /// sitting in somebody's notes app is worse than one called Saturday.
    public static func heading(title: String?, day: CalendarDay) -> String {
        let trimmed = (title ?? "").trimmed()
        guard trimmed.isEmpty else { return trimmed }
        return day.representativeDate()
            .formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    /// A filename for the share sheet, so saving to Files does not produce "Untitled 3".
    public static func filename(title: String?, day: CalendarDay) -> String {
        let name = heading(title: title, day: day)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(day.rawValue) \(name).md"
    }
}

extension String {
    fileprivate func trimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
