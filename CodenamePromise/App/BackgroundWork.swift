import BackgroundTasks
import OSLog
import UIKit

private let log = Logger(subsystem: "com.codenamepromise.journal", category: "background")

/// Keeps a long, user-started job running after the app is left, and shows its progress
/// outside the app while it does.
///
/// On iOS 26 this is a continued-processing task: the system keeps the work going after the
/// person switches away or locks the phone, and shows it as a Live Activity on the Lock
/// Screen and in the Dynamic Island, with the title, a line of detail, and a progress bar.
/// Before iOS 26 there's no such thing, so it falls back to the usual few minutes of
/// background time.
///
/// Either way the work itself saves as it goes (both imports are resumable), so if iOS does
/// stop it, nothing done so far is lost and the next run carries on.
@MainActor
enum BackgroundWork {
    /// Matches `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    private static let identifierPrefix = "com.codenamepromise.journal.import"

    /// Reports progress to the system's Live Activity: items done, items in all, and a line
    /// such as "120 of 500 photos".
    typealias Report = @MainActor (_ done: Int, _ total: Int, _ detail: String) -> Void

    static func run(title: String, _ work: @MainActor (_ report: @escaping Report) async -> Void) async {
        UIApplication.shared.isIdleTimerDisabled = true
        // Background time as well, for the moment before the continued task starts and for
        // older systems that don't have one.
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: title) {
            log.info("background time ran out; progress is saved")
        }

        let continued: ContinuedTask? = if #available(iOS 26.0, *) {
            ContinuedTask(title: title, prefix: identifierPrefix)
        } else {
            nil
        }

        // If iOS ends the task (it decides when), coming back to the app asks for a new one,
        // so leaving again is covered rather than the rest of the import running unseen.
        nonisolated(unsafe) let renewing = continued
        let observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { renewing?.renewIfNeeded() }
        }

        await work { done, total, detail in
            continued?.update(done: done, total: total, detail: detail)
        }

        NotificationCenter.default.removeObserver(observer)
        continued?.finish()
        UIApplication.shared.endBackgroundTask(backgroundTask)
        UIApplication.shared.isIdleTimerDisabled = false
    }
}

/// One continued-processing task: asked for when the work starts, given progress as it goes,
/// and marked complete when it ends.
///
/// The work doesn't wait for the system to grant the task. It starts at once, in the
/// foreground, and the task is attached to it whenever it arrives, so a refusal (the system is
/// busy, the person has turned the feature off) costs nothing but the Live Activity.
@MainActor
private final class ContinuedTask {
    private let title: String
    private let prefix: String
    private var task: AnyObject?
    /// The system ended the last task before the work was done.
    private var expired = false
    private var last: (done: Int, total: Int, detail: String) = (0, 0, "Starting\u{2026}")
    private var finished = false

    @available(iOS 26.0, *)
    init(title: String, prefix: String) {
        self.title = title
        self.prefix = prefix
        submit()
    }

    /// Asks again after the system ended the previous task, if there's still work going.
    func renewIfNeeded() {
        guard expired, !finished, #available(iOS 26.0, *) else { return }
        expired = false
        submit()
    }

    @available(iOS 26.0, *)
    private func submit() {
        // A fresh identifier each time: one can be registered only once per launch.
        let identifier = "\(prefix).\(UUID().uuidString.prefix(8))"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            nonisolated(unsafe) let task = task
            MainActor.assumeIsolated {
                guard let self, let continued = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.attach(continued)
            }
        }
        guard registered else {
            log.error("continued-processing identifier isn't permitted in Info.plist")
            return
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: last.detail)
        request.strategy = .fail
        // Now or not at all (set above): the work is already running, so a task queued for
        // later would only show progress for something that has moved on.
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.info("continued-processing task not granted: \(error.localizedDescription)")
        }
    }

    @available(iOS 26.0, *)
    private func attach(_ continued: BGContinuedProcessingTask) {
        task = continued
        continued.expirationHandler = { [weak self] in
            nonisolated(unsafe) let continued = continued
            // The system needed the time back. What's done is saved, the work carries on when
            // the app is next open, and a new task is asked for then.
            continued.updateTitle(continued.title, subtitle: "Paused. Open DumpNotes to carry on.")
            continued.setTaskCompleted(success: false)
            // Called on a background queue, not the main one: asserting the main actor here
            // crashed the app every time iOS ended the task. Hop over instead.
            nonisolated(unsafe) let owner = self
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    owner?.task = nil
                    owner?.expired = true
                }
            }
        }
        if finished {
            continued.setTaskCompleted(success: true)
            task = nil
        } else {
            show(last)
        }
    }

    func update(done: Int, total: Int, detail: String) {
        last = (done, total, detail)
        show(last)
    }

    func finish() {
        finished = true
        guard #available(iOS 26.0, *), let continued = task as? BGContinuedProcessingTask else { return }
        continued.progress.completedUnitCount = continued.progress.totalUnitCount
        continued.setTaskCompleted(success: true)
        task = nil
    }

    private func show(_ state: (done: Int, total: Int, detail: String)) {
        guard #available(iOS 26.0, *), let continued = task as? BGContinuedProcessingTask else { return }
        continued.progress.totalUnitCount = Int64(max(state.total, 1))
        continued.progress.completedUnitCount = Int64(min(state.done, state.total))
        continued.updateTitle(title, subtitle: state.detail)
    }
}
