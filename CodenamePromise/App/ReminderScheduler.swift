import CodenamePromiseCore
import Foundation
import SwiftData
import UserNotifications

/// The gentle nudge back, scheduled entirely on the device.
///
/// Deliberately a local notification rather than an email. Emailing someone about their
/// behaviour means holding an account for them and tracking their usage server-side, which
/// undoes the whole no-backend position — and for this particular job the local version is
/// simply better, because it can fire at the hour they actually write (see `WritingRhythm`)
/// and it knows nothing anyone could leak.
///
/// Permission is asked for at the point of use, never at launch. A journaling app that
/// demands notification access before you have written anything is asking for a favour it has
/// not earned yet.
@MainActor
@Observable
final class ReminderScheduler {
    /// Days of silence before a nudge. Long enough that a busy week goes unremarked.
    static let idleDays = 5

    private static let identifier = "journal.nudge"
    private let center = UNUserNotificationCenter.current()

    private(set) var isEnabled = false
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    /// How often to remind.
    enum Frequency: String, CaseIterable, Identifiable {
        /// One nudge after a few quiet days, at the hour they usually write.
        case whenAway
        case daily
        case weekly

        var id: String { rawValue }
        var label: String {
            switch self {
            case .whenAway: "When I\u{2019}ve been away"
            case .daily: "Every day"
            case .weekly: "Every week"
            }
        }
    }

    // Stored as plain defaults: it's a preference about this phone, not journal data.
    var frequency: Frequency {
        didSet { defaults.set(frequency.rawValue, forKey: "reminder.frequency") }
    }
    /// Minutes past midnight, for daily and weekly.
    var minuteOfDay: Int {
        didSet { defaults.set(minuteOfDay, forKey: "reminder.minuteOfDay") }
    }
    /// 1 is Sunday, as `Calendar` counts. For weekly.
    var weekday: Int {
        didSet { defaults.set(weekday, forKey: "reminder.weekday") }
    }

    private let defaults = UserDefaults.standard

    init() {
        frequency = defaults.string(forKey: "reminder.frequency").flatMap(Frequency.init(rawValue:)) ?? .whenAway
        minuteOfDay = defaults.object(forKey: "reminder.minuteOfDay") as? Int ?? 20 * 60
        weekday = defaults.object(forKey: "reminder.weekday") as? Int ?? 1
    }

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
        isEnabled = authorization == .authorized || authorization == .provisional
    }

    /// Asks, then schedules. Returns whether it is now on.
    @discardableResult
    func enable(using store: DraftStore) async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            await refreshAuthorization()
            if granted { reschedule(using: store) }
            return granted
        } catch {
            await refreshAuthorization()
            return false
        }
    }

    func disable() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        isEnabled = false
    }

    /// Recomputed rather than incremented: there is exactly one pending nudge at any time,
    /// replaced whenever the picture changes. Call after writing, and on becoming active.
    func reschedule(using store: DraftStore) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        guard isEnabled else { return }

        // A fixed time repeats on its own; only "when I've been away" depends on the journal.
        if frequency != .whenAway {
            let content = UNMutableNotificationContent()
            content.title = frequency == .daily ? "Anything from today?" : "Anything from this week?"
            content.body = "Thirty seconds is enough. Dump it and arrange it later."
            content.sound = .default
            var components = DateComponents()
            components.hour = minuteOfDay / 60
            components.minute = minuteOfDay % 60
            if frequency == .weekly { components.weekday = weekday }
            center.add(UNNotificationRequest(
                identifier: Self.identifier,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            ))
            return
        }

        let written = recentlyWritten(in: store)
        guard let lastWrote = written.first else { return }

        // Their hour if there is enough history to know it; otherwise a defensible evening.
        let hour = WritingRhythm.usualHour(of: written) ?? 20

        guard let fireAt = WritingRhythm.nextNudge(
            lastWrote: lastWrote, idleDays: Self.idleDays, preferredHour: hour
        ) else { return }

        let content = UNMutableNotificationContent()
        // No guilt, no count of days missed. An invitation, in the same voice as the rest
        // of the app.
        content.title = "Still here when you are"
        content.body = "A few days are waiting to be written up."
        content.sound = .default

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: fireAt
        )
        center.add(UNNotificationRequest(
            identifier: Self.identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        ))
    }

    /// When the most recently written entries were last changed, newest first.
    ///
    /// Only the latest couple of hundred. This runs as the app leaves, on the main thread,
    /// and reading every entry of a long journal (and decoding each one's text to see whether
    /// it's empty) to find the newest was most of the cost of going to the background. The
    /// recent ones are also the better guide to the hour someone writes at now.
    private func recentlyWritten(in store: DraftStore) -> [Date] {
        var descriptor = FetchDescriptor<EntryDraft>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 200
        guard let drafts = try? store.context.fetch(descriptor) else { return [] }
        return drafts.filter { !$0.content.isEmpty }.map(\.updatedAt)
    }

    /// What is actually queued. Used by the settings row, and by the test hook below.
    func pendingFireDate() async -> Date? {
        let requests = await center.pendingNotificationRequests()
        guard let request = requests.first(where: { $0.identifier == Self.identifier }),
              let trigger = request.trigger as? UNCalendarNotificationTrigger
        else { return nil }
        return trigger.nextTriggerDate()
    }
}
