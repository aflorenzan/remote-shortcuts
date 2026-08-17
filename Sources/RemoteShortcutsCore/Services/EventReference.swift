import Foundation

/// A reference to one occurrence of a calendar event.
///
/// EventKit gives every occurrence of a recurring series the same
/// `eventIdentifier`, so an id on its own cannot say *which* occurrence is
/// meant. Every write then resolves to the series master anchored at the
/// series' original start, which is how editing "this event" could rewrite the
/// whole series, delete nothing at all, or resurrect an occurrence the user had
/// already deleted.
///
/// The fix is a composite id: `<identifier>/RID=<seconds>`.
///
/// That format is not invented here — it is what EventKit itself produces when
/// an occurrence gets detached from its series. Matching it means the id this
/// API hands out and the id the platform hands back are the same string, so a
/// detached occurrence round-trips with no translation.
///
/// **The seconds are on Apple's epoch** (`timeIntervalSinceReferenceDate`,
/// 2001-01-01), not Unix. A real example from a detached occurrence,
/// `RID=825598800`, is 2027-03-01 on Apple's epoch and 1996-02-29 on Unix's —
/// so getting this wrong silently produces ids that never match the platform's.
public struct EventReference: Equatable {
    /// The series (or plain event) identifier, without any `/RID=` suffix.
    public let identifier: String
    /// The occurrence's start, or `nil` for "the series, as EventKit anchors it".
    public let occurrenceStart: Date?
    /// Exactly what the caller sent, so it can be tried verbatim first.
    public let raw: String

    static let occurrenceMarker = "/RID="

    public init(identifier: String, occurrenceStart: Date?, raw: String? = nil) {
        self.identifier = identifier
        self.occurrenceStart = occurrenceStart
        self.raw = raw ?? EventReference.compose(identifier: identifier, occurrenceStart: occurrenceStart)
    }

    /// Parses either form. A bare identifier keeps its historic meaning — the
    /// series master — so clients written against the old shape keep working.
    public static func parse(_ raw: String) -> EventReference {
        // `options: .backwards`: an identifier could in principle contain the
        // marker itself, and only the last one is the suffix we added.
        guard let marker = raw.range(of: occurrenceMarker, options: .backwards) else {
            return EventReference(identifier: raw, occurrenceStart: nil, raw: raw)
        }

        let identifier = String(raw[raw.startIndex..<marker.lowerBound])
        let suffix = String(raw[marker.upperBound...])

        // If the suffix is not a number this is not our composite form. Treat
        // the whole string as an identifier rather than guessing, so an
        // EventKit id that happens to contain `/RID=` still resolves as itself.
        guard !identifier.isEmpty, let seconds = Double(suffix) else {
            return EventReference(identifier: raw, occurrenceStart: nil, raw: raw)
        }

        return EventReference(
            identifier: identifier,
            occurrenceStart: Date(timeIntervalSinceReferenceDate: seconds),
            raw: raw
        )
    }

    /// The composite form, or the bare identifier when there is no occurrence.
    public var composite: String {
        EventReference.compose(identifier: identifier, occurrenceStart: occurrenceStart)
    }

    static func compose(identifier: String, occurrenceStart: Date?) -> String {
        guard let start = occurrenceStart else { return identifier }
        // Whole seconds: occurrence starts land on minute boundaries in
        // practice, and a fractional component in an id would be noise.
        return "\(identifier)\(occurrenceMarker)\(Int(start.timeIntervalSinceReferenceDate.rounded()))"
    }

    /// Strips a `/RID=` suffix. A detached occurrence's own `eventIdentifier`
    /// already carries one, so comparing identifiers needs both sides bare.
    public static func baseIdentifier(of identifier: String) -> String {
        parse(identifier).identifier
    }

    public var isOccurrencePinned: Bool { occurrenceStart != nil }
}
