import CodenamePromiseCore
import SwiftUI

/// The strip at the foot of an entry: its name, and everything true *about* it rather than
/// in it.
///
/// Shared by both densities, which is the point. Collapsing an entry means dropping its body
/// and keeping its label, so compact is this view on its own and comfortable is this view
/// under some content - one object, not two designs that have to be kept in step.
///
/// Gathering the facts here is also what lets the body above be nothing but the entry: no
/// timestamp sharing a baseline with somebody's evening.
struct EntryTitleBar: View {
    let summary: DraftSummary
    /// False when it is the whole row and there is nothing above it to divide from.
    var showsTopEdge: Bool = true
    /// Whether a Notion database is connected at all. Decides whether "not synced" is a
    /// status or just noise. See `showsStatus`.
    var hasDestination: Bool = false

    /// The name of the entry, and everything that is true *about* it rather than in it.
    ///
    /// One strip at the bottom on its own ground: the page icon, the title, and the quiet
    /// facts pushed to the right. Gathering them here is what lets the body above be nothing
    /// but the entry - no timestamps sharing a baseline with somebody's evening.
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: kindSymbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(kindTint)
                .frame(width: 15)
                .accessibilityLabel(kindLabel)

            Text(summary.title)
                .font(Type.journal(15.5, 600))
                .foregroundStyle(Brand.ink)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            if showsStatus {
                Image(systemName: statusIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusTint)
                    .accessibilityLabel(statusLabel)
            }
            if summary.pendingRecordings > 0 {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Brand.waiting)
                    .accessibilityLabel("\(summary.pendingRecordings) to transcribe")
            }
            if summary.isFormatted {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Brand.ai)
                    .accessibilityLabel("formatted")
            }

            // Fixed, so it is the title that gives way on a narrow row and not this.
            //
            // A negative layout priority let the HStack squeeze it to almost nothing against
            // a long title, and Text answers a width it cannot fit by wrapping: "edited 1:25
            // AM" came out as seven stacked lines and made the card four times taller than
            // its neighbours.
            Text(summary.edited)
                .font(Type.caption(10.5))
                .foregroundStyle(Brand.muted.opacity(0.7))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.panel)
        .overlay(alignment: .top) {
            // Only when there is something above it to be separated from.
            if showsTopEdge {
                Rectangle().fill(Brand.edge).frame(height: 1)
            }
        }
    }

    /// One symbol per state, never shared.
    ///
    /// The previous set used the same glyph for "not synced" and "edited since sync", which
    /// makes a symbol decorative rather than informative - you had to read the words anyway,
    /// so the icon was costing space and adding doubt. These are all from the cloud family
    /// so they read as one vocabulary about one thing, and each state owns exactly one.
    /// Sync only when it says something.
    ///
    /// With no Notion connected every single card carried "not synced", which is not a status
    /// so much as a restatement of the setup: nothing is synced, nothing was going to be, and
    /// a symbol repeated on every row in a list is decoration with a tooltip. The states worth
    /// a glyph are the ones that differ from what you would assume - something failed,
    /// something is in flight, something arrived, something changed since it arrived.
    ///
    /// "Not synced" survives only where a destination exists, because there it means an entry
    /// that could have gone and has not.
    private var showsStatus: Bool {
        switch summary.sync {
        case .hidden: false
        case .failed, .syncing, .synced, .unsyncedChanges: true
        case .notSynced: hasDestination
        }
    }

    /// What is *in* the entry, which is the one thing this slot can say that the title cannot.
    ///
    /// Borrowed from Notion, where the page glyph means "this row is a page" and is worth its
    /// space because a row might not be one. Here every row is an entry, so the same icon on
    /// every card said nothing at all - decorative, and by the same argument that retired the
    /// duplicated sync glyphs, costing space to add doubt.
    ///
    /// It now names the entry's contents, using the capture colours from the Dump screen so
    /// the vocabulary is one the person already learned: pink is video, green is photos,
    /// violet is a recording. Text-only stays grey, because it is the ordinary case and
    /// colour here marks the exception - the same rule the sync badges follow.
    ///
    /// This matters most in the compact density, where the strip is the whole row and this is
    /// the only sign of what is inside without opening it.
    private var kindSymbol: String {
        if hasVideo { return "play.rectangle.fill" }
        if summary.mediaCount > 0 { return "photo.fill" }
        if summary.pendingRecordings > 0 { return "waveform" }
        return "text.alignleft"
    }

    private var kindTint: Color {
        if hasVideo { return Brand.Mode.video }
        if summary.mediaCount > 0 { return Brand.Mode.photo }
        if summary.pendingRecordings > 0 { return Brand.Mode.voice }
        return Brand.muted
    }

    private var kindLabel: String {
        if hasVideo { return "Has video" }
        if summary.mediaCount > 0 { return "\(summary.mediaCount) photos" }
        if summary.pendingRecordings > 0 { return "Has a recording" }
        return "Text only"
    }

    private var hasVideo: Bool { summary.thumbnails.contains(where: \.isVideo) }

    private var statusLabel: String {
        switch summary.sync {
        case .hidden: ""
        case .syncing: "syncing"
        case .failed: "sync failed"
        case .synced: "synced"
        case .unsyncedChanges: "unsynced changes"
        case .notSynced: "not synced"
        }
    }

    private var statusIcon: String {
        switch summary.sync {
        case .hidden: "icloud.slash"
        case .syncing: "arrow.up.circle"
        case .failed: "exclamationmark.icloud"
        case .synced: "checkmark.icloud.fill"
        case .unsyncedChanges: "arrow.triangle.2.circlepath"
        case .notSynced: "icloud.slash"
        }
    }

    /// Amber-and-bold was reserved for the *normal* state, which is backwards twice over.
    ///
    /// "Sync is optional — an entry that never syncs is complete and valid" is a design tenet,
    /// not a caveat, so an entry sitting unsynced has nothing wrong with it and must not be
    /// dressed as a warning. And because most entries are in that state most of the time, the
    /// list came out covered in amber — at which point amber stops distinguishing anything and
    /// is merely loud. Same failure as violet-on-everything, in a colour that means danger.
    ///
    /// Colour now marks the exception. A failure is red because a failure is genuinely news.
    /// Syncing is violet because it is happening right now and will stop. Everything else is
    /// grey, and reads by its symbol and its word, which was always enough.
    private var statusTint: Color {
        switch summary.sync {
        case .failed: Brand.failed
        case .syncing: Brand.violet
        case .synced, .unsyncedChanges, .notSynced, .hidden: Brand.muted
        }
    }
}
