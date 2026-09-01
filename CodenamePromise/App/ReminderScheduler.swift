import CodenamePromiseCore
import Foundation
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

        guard let drafts = try? store.allDrafts(), !drafts.isEmpty else { return }
        let written = drafts.filter { !$0.content.isEmpty }
        guard let lastWrote = written.map(\.updatedAt).max() else { return }

        // Their hour if there is enough history to know it; otherwise a defensible evening.
        let hour = WritingRhythm.usualHour(of: written.map(\.updatedAt)) ?? 20

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

    /// What is actually queued. Used by the settings row, and by the test hook below.
    func pendingFireDate() async -> Date? {
        let requests = await center.pendingNotificationRequests()
        guard let request = requests.first(where: { $0.identifier == Self.identifier }),
              let trigger = request.trigger as? UNCalendarNotificationTrigger
        else { return nil }
        return trigger.nextTriggerDate()
    }
}
