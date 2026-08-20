import Foundation

/// The rule for telling a split series from a detached occurrence.
///
/// Separated from EventKit so it can be tested. It needs to be: the first
/// version of this check asked `EKEvent.isDetached` after saving, which is
/// never refreshed on the in-memory object, so the guard could not fire — and
/// nothing in the build said so. Every input here is a plain value read *after*
/// the save, and none of them is that flag.
public enum SpanOutcome {
    /// - Parameters:
    ///   - savedEventStillRecurring: `hasRecurrenceRules` on the saved event,
    ///     read after the save. A split leaves this event as master of the new
    ///     series, so it keeps its rules; a detached occurrence is a standalone
    ///     event with none. Unlike `isDetached`, this one is refreshed.
    ///   - laterOccurrenceKeptOldTitle: whether an occurrence after this one
    ///     still shows the pre-edit title, read back out of the store. Only
    ///     meaningful when the edit changed the title; `false` otherwise.
    public static func detachedInsteadOfSplit(
        savedEventStillRecurring: Bool,
        laterOccurrenceKeptOldTitle: Bool
    ) -> Bool {
        !savedEventStillRecurring || laterOccurrenceKeptOldTitle
    }
}
