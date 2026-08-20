import Foundation

/// The rule for telling a split series from a detached occurrence.
///
/// Separated from EventKit so it can be tested, and deliberately conservative.
///
/// A note on where this came from, because the history matters more than the
/// rule: an earlier version asked `EKEvent.isDetached` after saving and was
/// replaced on the strength of testing that turned out to be invalid — the
/// requests under test had sent `span` in the query, where `PATCH` never read
/// it, so every one of them ran as `this_event` and changed exactly one
/// occurrence. That is not `future_events` failing; that is `this_event`
/// working. **No detachment has ever been observed on real hardware.**
///
/// So this is a guard against EventKit behaving badly, not a description of
/// anything it does. It is kept because a wrong `200` on a calendar write is
/// expensive and the check is cheap — but it is tuned to stay quiet, since the
/// only failure mode anyone has actually seen from it is a false alarm.
public enum SpanOutcome {
    /// - Parameters:
    ///   - savedEventStillRecurring: `hasRecurrenceRules` on the saved event,
    ///     read after the save. A split leaves this event heading the new
    ///     series, so it keeps its rules; a detached occurrence has none.
    ///   - laterOccurrencesRemainInOldSeries: whether the original series still
    ///     has occurrences after this one, read back out of the store.
    ///   - laterOccurrenceKeptOldTitle: whether one of those still shows the
    ///     pre-edit title. Only meaningful when the edit changed the title;
    ///     `false` otherwise.
    ///
    /// The first two are required **together**, which is the point. Editing the
    /// last occurrence of a series with `future_events` legitimately leaves an
    /// event with no recurrence rules — there is nothing after it to recur —
    /// and flagging that would fail a correct edit. Losing the rules only means
    /// something went wrong if the later occurrences were left behind.
    public static func detachedInsteadOfSplit(
        savedEventStillRecurring: Bool,
        laterOccurrencesRemainInOldSeries: Bool,
        laterOccurrenceKeptOldTitle: Bool
    ) -> Bool {
        if laterOccurrenceKeptOldTitle { return true }
        return !savedEventStillRecurring && laterOccurrencesRemainInOldSeries
    }
}
