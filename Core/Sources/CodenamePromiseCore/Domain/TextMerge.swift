import Foundation

/// Reconciling an editor buffer with text that arrived from elsewhere.
///
/// The capture editor binds to an in-memory buffer rather than to the model (ADR-001), which
/// means the model can change underneath it — a transcript merged by the queue is the real
/// case. Before this existed, the editor simply wrote its buffer back on the next commit, so
/// a dictation could be transcribed, saved, and then overwritten a moment later by a stale
/// buffer. The words arrived and were destroyed.
///
/// External writes are append-only, which is what makes a correct merge possible without a
/// full diff: if the model still begins with the text the buffer was based on, everything
/// after that prefix is the addition.
public enum TextMerge {

    /// Folds an external addition into a buffer that may also have local edits.
    ///
    /// - Parameters:
    ///   - buffer: what the editor currently shows, including unsaved typing.
    ///   - baseline: the model text the buffer was last in step with.
    ///   - current: the model text now.
    /// - Returns: the buffer with any external addition appended.
    public static func absorbing(buffer: String, baseline: String, current: String) -> String {
        guard current != baseline else { return buffer }

        if current.hasPrefix(baseline) {
            let addition = String(current.dropFirst(baseline.count))
            // The buffer may already contain it — a second absorb of the same change, or a
            // commit that raced. Appending twice would duplicate the user's words.
            guard !addition.isEmpty, !buffer.hasSuffix(addition) else { return buffer }
            return buffer + addition
        }

        // The model diverged in a way this can't reconcile. The model wins: losing a few
        // keystrokes is recoverable, losing a dictation is the failure this project exists
        // to prevent.
        return current
    }
}
