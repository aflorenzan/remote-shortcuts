import CoreGraphics
import EventKit
import Foundation

/// Calendars and Reminders through EventKit — Apple's own framework, so every
/// account the Mac already syncs (iCloud, Google, Exchange, CalDAV, local)
/// is visible with no extra credentials anywhere.
public final class EventKitService: @unchecked Sendable {
    /// `EKEventStore` is not documented as thread-safe and mutating it from
    /// several connection queues at once produces sporadic save failures, so
    /// every touch of the store is serialised here.
    private let queue = DispatchQueue(label: "com.remoteshortcuts.eventkit")
    private let store = EKEventStore()

    public init() {}

    // MARK: - Authorisation

    /// Access levels, including macOS 14's write-only grant.
    ///
    /// `writeOnly` has to be its own case. Collapsing it into `granted` — which
    /// is what this did — is silently dangerous: with write-only calendar
    /// access, reads do not fail. `calendars(for:)` returns a single placeholder
    /// (`VIRTUAL_APP_CALENDAR_UUID`) and event queries return empty, so a
    /// machine with ten real calendars answered `200 {"count": 0}` and no client
    /// could tell "nothing scheduled" from "not allowed to look".
    public enum Access {
        case granted
        case writeOnly
        case denied
        case notDetermined
        case restricted

        /// Whether reads can be trusted. Write-only can create but not see.
        var allowsReading: Bool { self == .granted }
        var allowsWriting: Bool { self == .granted || self == .writeOnly }
    }

    /// macOS 14 split `.authorized` into `.fullAccess` / `.writeOnly`; both the
    /// old and new cases are mapped here so one binary covers macOS 13+.
    public static func authorisationStatus(for entity: EKEntityType) -> Access {
        let status = EKEventStore.authorizationStatus(for: entity)
        if #available(macOS 14.0, *) {
            if status == .fullAccess { return .granted }
            if status == .writeOnly { return .writeOnly }
        }
        switch status {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        // `.fullAccess` / `.writeOnly` are handled above on macOS 14+; this
        // covers any case a future SDK adds.
        default: return .denied
        }
    }

    /// Triggers the macOS permission prompt. Called by `preflight` during
    /// install so the user approves everything once, up front.
    @discardableResult
    public func requestAccess(to entity: EKEntityType, timeout: TimeInterval = 120) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false

        let completion: (Bool, Error?) -> Void = { result, error in
            granted = result
            if let error { Log.debug("EventKit access request error: \(error.localizedDescription)") }
            semaphore.signal()
        }

        if #available(macOS 14.0, *) {
            switch entity {
            case .event: store.requestFullAccessToEvents(completion: completion)
            case .reminder: store.requestFullAccessToReminders(completion: completion)
            @unknown default: return false
            }
        } else {
            store.requestAccess(to: entity, completion: completion)
        }

        _ = semaphore.wait(timeout: .now() + timeout)
        return granted
    }

    /// The status TCC reports, corrected by what the process can actually do.
    ///
    /// `authorizationStatus(for:)` keeps saying `notDetermined` after the user
    /// has granted access, until this process exercises that access for the
    /// first time. A permissions endpoint that reports it raw therefore claims
    /// nothing is granted right up until some other call proves otherwise,
    /// which reads as "TCC is broken" when everything is fine.
    ///
    /// `calendars(for:)` never prompts and returns an empty array without
    /// access, so it is a safe probe for a read-only endpoint to make.
    public func effectiveAccess(for entity: EKEntityType) -> Access {
        let declared = EventKitService.authorisationStatus(for: entity)
        guard declared == .notDetermined else { return declared }

        // With write-only access this returns one placeholder calendar
        // (VIRTUAL_APP_CALENDAR_UUID), so counting rows is not enough — filter
        // it out or the probe reports full access.
        let visible = (try? sync { store in
            store.calendars(for: entity).filter { !EventKitService.isPlaceholder($0) }.count
        }) ?? 0
        return visible > 0 ? .granted : .notDetermined
    }

    enum AccessKind { case read, write }

    /// Checks access for what the caller is about to do.
    ///
    /// Reads and writes are distinguished because a write-only grant permits one
    /// and quietly ruins the other: reads come back empty rather than failing.
    /// A caller told "200, no events" makes worse decisions than one told
    /// "you cannot read calendars".
    private func requireAccess(_ entity: EKEntityType, for kind: AccessKind = .read) throws {
        let service = entity == .event ? "Calendars" : "Reminders"
        // Effective, not declared: otherwise a granted-but-not-yet-exercised
        // permission sends every first request into a 60-second prompt wait.
        let access = effectiveAccess(for: entity)

        switch access {
        case .granted:
            return
        case .writeOnly:
            if kind == .write { return }
            throw APIError.permissionDenied(
                service: service,
                detail: "This Mac granted write-only access, so events can be created but not read. Reading would silently return nothing rather than fail, so the request is refused instead."
            )
        case .notDetermined:
            // Ask now: a LaunchAgent session can still present the prompt.
            if requestAccess(to: entity, timeout: 60) { return }
            throw APIError.permissionDenied(
                service: service,
                detail: "The permission prompt was not accepted. Run 'remote-shortcuts preflight' from a terminal to grant it."
            )
        case .denied:
            throw APIError.permissionDenied(service: service, detail: "Access was previously denied.")
        case .restricted:
            throw APIError.permissionDenied(service: service, detail: "Access is restricted by a device policy or parental controls.")
        }
    }

    /// The stand-in calendar EventKit exposes under a write-only grant. It is
    /// not a calendar the user has, and reporting it as one is misleading.
    static func isPlaceholder(_ calendar: EKCalendar) -> Bool {
        calendar.calendarIdentifier.uppercased().contains("VIRTUAL_APP_CALENDAR")
    }

    private func sync<T>(_ work: @escaping (EKEventStore) throws -> T) throws -> T {
        try queue.sync { try work(store) }
    }

    // MARK: - Calendars

    public func listCalendars(entity: EKEntityType) throws -> [[String: Any]] {
        try requireAccess(entity)
        return try sync { store in
            store.calendars(for: entity)
                .filter { !EventKitService.isPlaceholder($0) }
                .map(EventKitService.serialise(calendar:))
        }
    }

    static func serialise(calendar: EKCalendar) -> [String: Any] {
        [
            "id": calendar.calendarIdentifier,
            "title": calendar.title,
            "type": describe(calendarType: calendar.type),
            "source": JSONValueOrNull(calendar.source?.title),
            "allows_modification": calendar.allowsContentModifications,
            "is_subscribed": calendar.isSubscribed,
            "color": JSONValueOrNull(calendar.cgColor.flatMap(EventKitService.hexString(from:))),
        ]
    }

    static func describe(calendarType: EKCalendarType) -> String {
        switch calendarType {
        case .local: return "local"
        case .calDAV: return "caldav"
        case .exchange: return "exchange"
        case .subscription: return "subscription"
        case .birthday: return "birthday"
        @unknown default: return "unknown"
        }
    }

    /// EventKit hands back a `CGColor`; `EKCalendar.color` is an `NSColor` and
    /// would drag AppKit into a background service for no reason.
    ///
    /// The colour is converted to sRGB first. Reading `components` directly
    /// assumes an RGB space, and a calendar stored as greyscale has two
    /// components (white, alpha) — so the old code reported the alpha as the
    /// green channel and invented a blue one.
    static func hexString(from color: CGColor) -> String? {
        let resolved: CGColor
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB),
           let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil) {
            resolved = converted
        } else {
            resolved = color
        }

        guard let components = resolved.components, components.count >= 3 else { return nil }

        func channel(_ value: CGFloat) -> Int {
            Int((max(0, min(1, value)) * 255).rounded())
        }
        return String(format: "#%02X%02X%02X", channel(components[0]), channel(components[1]), channel(components[2]))
    }

    /// Resolves a calendar by identifier or by title (case-insensitive), so
    /// automations can be written against readable names.
    private func resolveCalendar(_ reference: String, entity: EKEntityType, in store: EKEventStore) throws -> EKCalendar {
        if let calendar = store.calendar(withIdentifier: reference) { return calendar }
        let candidates = store.calendars(for: entity).filter {
            $0.title.compare(reference, options: .caseInsensitive) == .orderedSame
        }
        if candidates.count > 1 {
            throw APIError.unprocessable("More than one calendar is named '\(reference)'. Use its 'id' instead — see GET /v1/calendars.")
        }
        guard let calendar = candidates.first else {
            throw APIError.notFound("No calendar named or identified by '\(reference)'")
        }
        return calendar
    }

    private func defaultCalendar(entity: EKEntityType, in store: EKEventStore) throws -> EKCalendar {
        let fallback = entity == .event
            ? store.defaultCalendarForNewEvents
            : store.defaultCalendarForNewReminders()
        guard let calendar = fallback else {
            throw APIError.unprocessable("This Mac has no default \(entity == .event ? "calendar" : "reminders list"). Pass 'calendar' explicitly.")
        }
        return calendar
    }

    // MARK: - Events

    public struct EventQuery {
        public var start: Date
        public var end: Date
        public var calendars: [String]?
        public var search: String?
        public var limit: Int

        public init(start: Date, end: Date, calendars: [String]? = nil, search: String? = nil, limit: Int = 250) {
            self.start = start
            self.end = end
            self.calendars = calendars
            self.search = search
            self.limit = limit
        }
    }

    public func events(matching query: EventQuery) throws -> [[String: Any]] {
        try requireAccess(.event)
        guard query.end > query.start else {
            throw APIError.badRequest("'end' must be after 'start'")
        }
        // EKEventStore refuses predicates spanning more than four years.
        guard query.end.timeIntervalSince(query.start) <= 4 * 365 * 24 * 3600 else {
            throw APIError.badRequest("The requested range is longer than 4 years, which EventKit does not support")
        }

        return try sync { store in
            var calendars: [EKCalendar]?
            if let references = query.calendars {
                calendars = try references.map { try self.resolveCalendar($0, entity: .event, in: store) }
            }
            let predicate = store.predicateForEvents(withStart: query.start, end: query.end, calendars: calendars)
            var events = store.events(matching: predicate)

            if let search = query.search?.lowercased(), !search.isEmpty {
                events = events.filter {
                    ($0.title?.lowercased().contains(search) ?? false)
                        || ($0.notes?.lowercased().contains(search) ?? false)
                        || ($0.location?.lowercased().contains(search) ?? false)
                }
            }

            return events
                .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
                .prefix(query.limit)
                .map(EventKitService.serialise(event:))
        }
    }

    public func event(withIdentifier identifier: String) throws -> [String: Any] {
        try requireAccess(.event)
        return try sync { store in
            let resolved = try self.resolve(identifier, in: store)
            return EventKitService.serialise(event: resolved.event)
        }
    }

    struct ResolvedEvent {
        let event: EKEvent
        /// True when the caller named a specific occurrence, so `.thisEvent`
        /// and `.futureEvents` act from *there* rather than from the series
        /// start. That is the whole point of the composite id.
        let pinnedToOccurrence: Bool
    }

    /// Resolves either id form to a concrete `EKEvent`.
    ///
    /// Order matters. The verbatim lookup comes first because a detached
    /// occurrence's own identifier already contains a `/RID=` suffix, and
    /// EventKit will resolve that string directly — re-deriving it from the
    /// parsed parts would be a slower route to the same object, and would fail
    /// if the suffix were ever not a timestamp.
    /// `preferOccurrenceQuery` skips the identifier shortcut and locates the
    /// occurrence through a date predicate instead.
    ///
    /// `EKSpan.futureEvents` is documented against an occurrence obtained from
    /// `events(matching:)`. An object from `event(withIdentifier:)` is not
    /// obviously the same thing, and a `.futureEvents` save on one was observed
    /// detaching that single occurrence rather than splitting the series. This
    /// makes the span operations take the documented route.
    func resolve(
        _ raw: String,
        in store: EKEventStore,
        preferOccurrenceQuery: Bool = false
    ) throws -> ResolvedEvent {
        let reference = EventReference.parse(raw)

        if let event = store.event(withIdentifier: raw), !preferOccurrenceQuery {
            guard let wantedStart = reference.occurrenceStart else {
                return ResolvedEvent(event: event, pinnedToOccurrence: false)
            }
            // Do not take the lookup's word for it. If EventKit accepts its own
            // composite format loosely and hands back the series master,
            // treating that as a pinned occurrence would skip the staleness
            // checks below and write to the wrong occurrence — reintroducing
            // exactly the silent no-op and resurrection this is meant to fix.
            // Confirm it starts where the id says; otherwise fall through and
            // locate the occurrence properly.
            let actualStart = event.startDate ?? .distantPast
            if abs(actualStart.timeIntervalSince(wantedStart)) < 1 {
                return ResolvedEvent(event: event, pinnedToOccurrence: true)
            }
        }

        guard let start = reference.occurrenceStart else {
            guard let event = store.event(withIdentifier: reference.identifier) else {
                throw APIError.notFound("No event with id '\(raw)'")
            }
            // A bare id names the series, so re-fetch its first occurrence
            // through a query when a span operation needs one.
            if preferOccurrenceQuery, event.hasRecurrenceRules,
               let occurrence = self.occurrence(of: event, startingAt: event.startDate, in: store) {
                return ResolvedEvent(event: occurrence, pinnedToOccurrence: false)
            }
            return ResolvedEvent(event: event, pinnedToOccurrence: false)
        }

        if preferOccurrenceQuery, let master = store.event(withIdentifier: reference.identifier),
           let occurrence = self.occurrence(of: master, startingAt: start, in: store) {
            return ResolvedEvent(event: occurrence, pinnedToOccurrence: true)
        }

        // A composite id for an occurrence that has not been detached: the
        // identifier alone resolves to the master, so find the occupant of the
        // window the id names.
        guard let master = store.event(withIdentifier: reference.identifier) else {
            throw APIError.notFound("No event series with id '\(reference.identifier)'")
        }

        let predicate = store.predicateForEvents(
            withStart: start.addingTimeInterval(-1),
            end: start.addingTimeInterval(1),
            calendars: master.calendar.map { [$0] }
        )
        let occurrence = store.events(matching: predicate).first { candidate in
            EventReference.baseIdentifier(of: candidate.eventIdentifier ?? "") == reference.identifier
                && abs((candidate.startDate ?? .distantPast).timeIntervalSince(start)) < 1
        }

        guard let occurrence else {
            throw APIError.notFound(
                "No occurrence of '\(reference.identifier)' starts at \(DateParsing.format(start)). It may have been deleted or moved — query GET /v1/calendars/events for current ids."
            )
        }
        return ResolvedEvent(event: occurrence, pinnedToOccurrence: true)
    }

    public struct EventDraft {
        public var title: String?
        public var start: Date?
        public var end: Date?
        public var isAllDay: Bool?
        public var location: String?
        public var notes: String?
        public var url: String?
        public var calendar: String?
        public var timeZone: String?
        /// Minutes before the start; negative values are normalised.
        public var alarms: [Int]?
        public var availability: String?

        public init() {}
    }

    public func createEvent(_ draft: EventDraft) throws -> [String: Any] {
        try requireAccess(.event, for: .write)
        guard let title = draft.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw APIError.badRequest("Missing required field 'title'")
        }
        guard let start = draft.start else {
            throw APIError.badRequest("Missing required field 'start'")
        }

        return try sync { store in
            let event = EKEvent(eventStore: store)
            let calendar = try draft.calendar.map { try self.resolveCalendar($0, entity: .event, in: store) }
                ?? self.defaultCalendar(entity: .event, in: store)
            guard calendar.allowsContentModifications else {
                throw APIError.forbidden("Calendar '\(calendar.title)' is read-only (subscribed or delegated).")
            }
            event.calendar = calendar
            event.title = title
            event.startDate = start
            event.isAllDay = draft.isAllDay ?? false
            // An all-day event still needs an end date; default to same day.
            event.endDate = draft.end ?? start.addingTimeInterval(event.isAllDay ? 0 : 3600)

            guard event.endDate >= event.startDate else {
                throw APIError.badRequest("'end' must not be before 'start'")
            }

            try EventKitService.apply(draft, to: event)

            do {
                try store.save(event, span: .thisEvent, commit: true)
            } catch {
                throw APIError.upstreamFailure("Calendar rejected the event: \(error.localizedDescription)")
            }
            return EventKitService.serialise(event: event)
        }
    }

    public func updateEvent(identifier: String, draft: EventDraft, span: EKSpan) throws -> [String: Any] {
        try requireAccess(.event, for: .write)
        return try sync { store in
            let resolved = try self.resolve(
                identifier,
                in: store,
                preferOccurrenceQuery: span == .futureEvents
            )
            let event = resolved.event
            let wasDetached = event.isDetached
            let wasRecurring = event.hasRecurrenceRules
            guard event.calendar?.allowsContentModifications ?? false else {
                throw APIError.forbidden("Event belongs to a read-only calendar.")
            }

            // Same phantom as in `deleteEvent`, with a nastier outcome: saving
            // the resolved master with `.thisEvent` makes EventKit
            // re-materialise an occurrence the user had already deleted.
            let target = EventKitService.OccurrenceRef(event)
            if target.isRecurring, span == .thisEvent, !resolved.pinnedToOccurrence,
               !self.occurrenceExists(target, in: store) {
                throw APIError.notFound(
                    "The occurrence this id points at no longer exists — it was already deleted or detached from the series. Editing it would recreate it. Query GET /v1/calendars/events to get a current id."
                )
            }

            if let title = draft.title { event.title = title }
            if let start = draft.start { event.startDate = start }
            if let end = draft.end { event.endDate = end }
            if let isAllDay = draft.isAllDay { event.isAllDay = isAllDay }
            if let reference = draft.calendar {
                let calendar = try self.resolveCalendar(reference, entity: .event, in: store)
                guard calendar.allowsContentModifications else {
                    throw APIError.forbidden("Calendar '\(calendar.title)' is read-only.")
                }
                event.calendar = calendar
            }
            try EventKitService.apply(draft, to: event)

            guard event.endDate >= event.startDate else {
                throw APIError.badRequest("'end' must not be before 'start'")
            }

            do {
                try store.save(event, span: span, commit: true)
            } catch {
                throw APIError.upstreamFailure("Calendar rejected the update: \(error.localizedDescription)")
            }

            // Confirm EventKit did what was asked rather than something else.
            //
            // A `.futureEvents` save on a series was observed *detaching* the
            // single occurrence instead of splitting the series: the later
            // occurrences kept their old values while the call returned 200.
            // Reporting success for an operation that did something different
            // is worse than failing, so detect it and say so.
            if span == .futureEvents, wasRecurring, !wasDetached, event.isDetached {
                throw APIError.upstreamFailure(
                    "Calendar applied this edit to one occurrence only, not to this and all later ones. "
                        + "EventKit detached the occurrence instead of splitting the series, so the later "
                        + "occurrences are unchanged. The edit to this occurrence has been kept. To change "
                        + "the rest, edit each one using the composite ids from GET /v1/calendars/events."
                )
            }
            return EventKitService.serialise(event: event)
        }
    }

    public func deleteEvent(identifier: String, span: EKSpan) throws {
        try requireAccess(.event, for: .write)
        try sync { store in
            // Go through `resolve`, not a bare identifier lookup: a composite
            // id names one occurrence, and `event(withIdentifier:)` on a series
            // always hands back the master anchored at the series' original
            // start — whether or not that occurrence still exists. Deleting
            // that phantom silently succeeds, and reporting a deletion that did
            // not happen is worse than any error.
            let resolved = try self.resolve(
                identifier,
                in: store,
                preferOccurrenceQuery: span == .futureEvents
            )
            let event = resolved.event
            let seriesIdentifier = event.eventIdentifier.map(EventReference.baseIdentifier(of:))
            let deletionStart = event.startDate
            let deletionCalendar = event.calendar
            let wasRecurring = event.hasRecurrenceRules

            // Recurring events only, and only when the caller did not name a
            // specific occurrence: `resolve` already found the real one, so
            // there is nothing stale to guard against. For a one-off the
            // resolve above proved it exists, and gating an ordinary delete on
            // a post-hoc lookup would risk reporting failure for a deletion
            // that succeeded — that path already worked.
            let target = EventKitService.OccurrenceRef(event)
            let needsOccurrenceCheck = target.isRecurring
                && span == .thisEvent
                && !resolved.pinnedToOccurrence

            if needsOccurrenceCheck, !self.occurrenceExists(target, in: store) {
                throw APIError.notFound(
                    "The occurrence this id points at no longer exists — it was already deleted or detached from the series. Query GET /v1/calendars/events to get a current id."
                )
            }

            do {
                try store.remove(event, span: span, commit: true)
            } catch {
                throw APIError.upstreamFailure("Calendar rejected the deletion: \(error.localizedDescription)")
            }

            // Confirm the occurrence actually went away rather than trusting
            // that `remove` not throwing means it did.
            if needsOccurrenceCheck, self.occurrenceExists(target, in: store) {
                throw APIError.upstreamFailure(
                    "Calendar accepted the deletion but the occurrence is still present. Nothing was deleted."
                )
            }

            // For `future_events`, "did it work" means the later occurrences
            // are gone too — not just this one.
            if span == .futureEvents, wasRecurring,
               let seriesIdentifier, let deletionStart,
               self.hasOccurrences(
                   ofSeries: seriesIdentifier,
                   after: deletionStart,
                   calendar: deletionCalendar,
                   in: store
               ) {
                throw APIError.upstreamFailure(
                    "Calendar removed this occurrence but left the later ones in place, so the series was "
                        + "not truncated as 'future_events' asks. Delete the remaining occurrences "
                        + "individually using the composite ids from GET /v1/calendars/events."
                )
            }
        }
    }

    /// Identifies one occurrence: its series identifier plus where it sits.
    struct OccurrenceRef {
        let identifier: String?
        let start: Date?
        let isRecurring: Bool
        let calendar: EKCalendar?

        init(_ event: EKEvent) {
            self.identifier = event.eventIdentifier
            self.start = event.startDate
            self.isRecurring = event.hasRecurrenceRules
            self.calendar = event.calendar
        }
    }

    /// Finds the occurrence of `event` that starts at `start`, via a date
    /// predicate — the route EventKit's span semantics are defined against.
    private func occurrence(of event: EKEvent, startingAt start: Date?, in store: EKEventStore) -> EKEvent? {
        guard let start, let identifier = event.eventIdentifier else { return nil }
        let base = EventReference.baseIdentifier(of: identifier)
        let predicate = store.predicateForEvents(
            withStart: start.addingTimeInterval(-1),
            end: start.addingTimeInterval(1),
            calendars: event.calendar.map { [$0] }
        )
        return store.events(matching: predicate).first { candidate in
            EventReference.baseIdentifier(of: candidate.eventIdentifier ?? "") == base
                && abs((candidate.startDate ?? .distantPast).timeIntervalSince(start)) < 1
        }
    }

    /// Whether any occurrence of the series still starts after `start`.
    ///
    /// The window is a year, which covers any series worth calling
    /// `future_events` on without asking EventKit for an unbounded query.
    private func hasOccurrences(
        ofSeries identifier: String,
        after start: Date,
        calendar: EKCalendar?,
        in store: EKEventStore
    ) -> Bool {
        let predicate = store.predicateForEvents(
            withStart: start.addingTimeInterval(1),
            end: start.addingTimeInterval(365 * 24 * 3600),
            calendars: calendar.map { [$0] }
        )
        return store.events(matching: predicate).contains { candidate in
            EventReference.baseIdentifier(of: candidate.eventIdentifier ?? "") == identifier
        }
    }

    /// Whether the occurrence is really there.
    ///
    /// For a one-off event the identifier lookup is the answer. For a series it
    /// is not: the identifier resolves to the master anchored at the series'
    /// original start whether or not that occurrence still exists, so the only
    /// honest check is to look in the window it claims to occupy.
    private func occurrenceExists(_ target: OccurrenceRef, in store: EKEventStore) -> Bool {
        guard let identifier = target.identifier else { return false }
        guard target.isRecurring, let start = target.start else {
            return store.event(withIdentifier: identifier) != nil
        }

        let predicate = store.predicateForEvents(
            withStart: start.addingTimeInterval(-1),
            end: start.addingTimeInterval(1),
            calendars: target.calendar.map { [$0] }
        )
        return store.events(matching: predicate).contains { candidate in
            candidate.eventIdentifier == identifier
                && abs((candidate.startDate ?? .distantPast).timeIntervalSince(start)) < 1
        }
    }

    private static func apply(_ draft: EventDraft, to event: EKEvent) throws {
        if let location = draft.location { event.location = location }
        if let notes = draft.notes { event.notes = notes }
        if let raw = draft.url {
            guard let url = URL(string: raw), url.scheme != nil else {
                throw APIError.badRequest("Field 'url' must be an absolute URL")
            }
            event.url = url
        }
        if let identifier = draft.timeZone {
            guard let zone = TimeZone(identifier: identifier) else {
                throw APIError.badRequest("Unknown time zone '\(identifier)'")
            }
            event.timeZone = zone
        }
        if let availability = draft.availability {
            switch availability.lowercased() {
            case "busy": event.availability = .busy
            case "free": event.availability = .free
            case "tentative": event.availability = .tentative
            case "unavailable": event.availability = .unavailable
            default: throw APIError.badRequest("Field 'availability' must be busy, free, tentative or unavailable")
            }
        }
        if let alarms = draft.alarms {
            event.alarms?.forEach { event.removeAlarm($0) }
            for minutes in alarms {
                let offset = -abs(Double(minutes)) * 60
                event.addAlarm(EKAlarm(relativeOffset: offset))
            }
        }
    }

    /// The id handed to clients.
    ///
    /// For a recurring event this is the composite form, so each row of an
    /// expanded series is individually addressable. For a one-off it is the
    /// plain identifier, unchanged.
    static func referenceIdentifier(for event: EKEvent) -> String? {
        guard let identifier = event.eventIdentifier else { return nil }
        guard event.hasRecurrenceRules, let start = event.startDate else { return identifier }
        // A detached occurrence's identifier already carries the suffix.
        if identifier.contains(EventReference.occurrenceMarker) { return identifier }
        return EventReference(identifier: identifier, occurrenceStart: start).composite
    }

    static func serialise(event: EKEvent) -> [String: Any] {
        var payload: [String: Any] = [
            "id": JSONValueOrNull(referenceIdentifier(for: event)),
            // The series identifier, for callers that mean the whole series.
            "series_id": JSONValueOrNull(event.eventIdentifier.map(EventReference.baseIdentifier(of:))),
            "title": event.title ?? "",
            "start": DateParsing.formatOptional(event.startDate),
            "end": DateParsing.formatOptional(event.endDate),
            "all_day": event.isAllDay,
            "calendar": JSONValueOrNull(event.calendar?.title),
            "calendar_id": JSONValueOrNull(event.calendar?.calendarIdentifier),
            "location": JSONValueOrNull(event.location),
            "notes": JSONValueOrNull(event.notes),
            "url": JSONValueOrNull(event.url?.absoluteString),
            "time_zone": JSONValueOrNull(event.timeZone?.identifier),
            "is_recurring": event.hasRecurrenceRules,
            "status": describe(status: event.status),
            "last_modified": DateParsing.formatOptional(event.lastModifiedDate),
        ]

        if let alarms = event.alarms, !alarms.isEmpty {
            payload["alarms_minutes_before"] = alarms.map { Int((-$0.relativeOffset / 60).rounded()) }
        }
        if let attendees = event.attendees, !attendees.isEmpty {
            payload["attendees"] = attendees.map { attendee -> [String: Any] in
                [
                    "name": JSONValueOrNull(attendee.name),
                    "email": attendee.url.absoluteString.replacingOccurrences(of: "mailto:", with: ""),
                    "status": describe(participantStatus: attendee.participantStatus),
                ]
            }
        }
        if let organizer = event.organizer {
            payload["organizer"] = organizer.name ?? organizer.url.absoluteString
        }
        return payload
    }

    static func describe(status: EKEventStatus) -> String {
        switch status {
        case .none: return "none"
        case .confirmed: return "confirmed"
        case .tentative: return "tentative"
        case .canceled: return "cancelled"
        @unknown default: return "unknown"
        }
    }

    static func describe(participantStatus: EKParticipantStatus) -> String {
        switch participantStatus {
        case .unknown: return "unknown"
        case .pending: return "pending"
        case .accepted: return "accepted"
        case .declined: return "declined"
        case .tentative: return "tentative"
        case .delegated: return "delegated"
        case .completed: return "completed"
        case .inProcess: return "in_process"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Reminders

    public struct ReminderQuery {
        public var lists: [String]?
        public var completed: Bool?
        public var dueAfter: Date?
        public var dueBefore: Date?
        public var search: String?
        public var limit: Int

        public init(
            lists: [String]? = nil,
            completed: Bool? = nil,
            dueAfter: Date? = nil,
            dueBefore: Date? = nil,
            search: String? = nil,
            limit: Int = 250
        ) {
            self.lists = lists
            self.completed = completed
            self.dueAfter = dueAfter
            self.dueBefore = dueBefore
            self.search = search
            self.limit = limit
        }
    }

    public func reminders(matching query: ReminderQuery) throws -> [[String: Any]] {
        try requireAccess(.reminder)

        return try sync { store in
            var calendars: [EKCalendar]?
            if let references = query.lists {
                calendars = try references.map { try self.resolveCalendar($0, entity: .reminder, in: store) }
            }

            let predicate: NSPredicate
            switch query.completed {
            case .some(false):
                predicate = store.predicateForIncompleteReminders(
                    withDueDateStarting: query.dueAfter, ending: query.dueBefore, calendars: calendars
                )
            case .some(true):
                predicate = store.predicateForCompletedReminders(
                    withCompletionDateStarting: nil, ending: nil, calendars: calendars
                )
            case .none:
                predicate = store.predicateForReminders(in: calendars)
            }

            // `fetchReminders` is asynchronous; bridge it back to the caller.
            let semaphore = DispatchSemaphore(value: 0)
            var fetched: [EKReminder] = []
            store.fetchReminders(matching: predicate) { result in
                fetched = result ?? []
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 30) == .success else {
                throw APIError.timeout("Reminders did not respond within 30 seconds")
            }

            var reminders = fetched
            if query.completed == nil || query.completed == true {
                if let after = query.dueAfter {
                    reminders = reminders.filter { (EventKitService.dueDate(of: $0) ?? .distantFuture) >= after }
                }
                if let before = query.dueBefore {
                    reminders = reminders.filter { (EventKitService.dueDate(of: $0) ?? .distantPast) <= before }
                }
            }
            if let search = query.search?.lowercased(), !search.isEmpty {
                // `title` is an implicitly-unwrapped optional in EventKit;
                // treating it as one avoids a crash on a title-less item.
                reminders = reminders.filter {
                    ($0.title ?? "").lowercased().contains(search)
                        || ($0.notes?.lowercased().contains(search) ?? false)
                }
            }

            return reminders
                .sorted { EventKitService.sortKey($0) < EventKitService.sortKey($1) }
                .prefix(query.limit)
                .map(EventKitService.serialise(reminder:))
        }
    }

    /// `DateComponents.date` only resolves when the components carry a
    /// calendar, which EventKit does not always populate. Resolving against
    /// `Calendar.current` avoids silently reporting every due date as null.
    static func dueDate(of reminder: EKReminder) -> Date? {
        guard let components = reminder.dueDateComponents else { return nil }
        if let date = components.date { return date }
        return Calendar.current.date(from: components)
    }

    private static func sortKey(_ reminder: EKReminder) -> Date {
        EventKitService.dueDate(of: reminder) ?? reminder.creationDate ?? .distantFuture
    }

    public struct ReminderDraft {
        public var title: String?
        public var notes: String?
        public var list: String?
        public var due: Date?
        /// When false the due date carries no time component.
        public var dueHasTime: Bool = true
        public var priority: Int?
        public var completed: Bool?
        public var url: String?
        public var alarms: [Date]?

        public init() {}
    }

    public func createReminder(_ draft: ReminderDraft) throws -> [String: Any] {
        try requireAccess(.reminder, for: .write)
        guard let title = draft.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw APIError.badRequest("Missing required field 'title'")
        }

        return try sync { store in
            let reminder = EKReminder(eventStore: store)
            reminder.calendar = try draft.list.map { try self.resolveCalendar($0, entity: .reminder, in: store) }
                ?? self.defaultCalendar(entity: .reminder, in: store)
            reminder.title = title
            try EventKitService.apply(draft, to: reminder)

            do {
                try store.save(reminder, commit: true)
            } catch {
                throw APIError.upstreamFailure("Reminders rejected the item: \(error.localizedDescription)")
            }
            return EventKitService.serialise(reminder: reminder)
        }
    }

    public func updateReminder(identifier: String, draft: ReminderDraft) throws -> [String: Any] {
        try requireAccess(.reminder, for: .write)
        return try sync { store in
            let reminder = try self.fetchReminder(identifier: identifier, in: store)
            if let title = draft.title { reminder.title = title }
            if let reference = draft.list {
                reminder.calendar = try self.resolveCalendar(reference, entity: .reminder, in: store)
            }
            try EventKitService.apply(draft, to: reminder)

            do {
                try store.save(reminder, commit: true)
            } catch {
                throw APIError.upstreamFailure("Reminders rejected the update: \(error.localizedDescription)")
            }
            return EventKitService.serialise(reminder: reminder)
        }
    }

    public func deleteReminder(identifier: String) throws {
        try requireAccess(.reminder, for: .write)
        try sync { store in
            let reminder = try self.fetchReminder(identifier: identifier, in: store)
            do {
                try store.remove(reminder, commit: true)
            } catch {
                throw APIError.upstreamFailure("Reminders rejected the deletion: \(error.localizedDescription)")
            }
        }
    }

    private func fetchReminder(identifier: String, in store: EKEventStore) throws -> EKReminder {
        guard let item = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw APIError.notFound("No reminder with id '\(identifier)'")
        }
        return item
    }

    private static func apply(_ draft: ReminderDraft, to reminder: EKReminder) throws {
        if let notes = draft.notes { reminder.notes = notes }
        if let priority = draft.priority {
            guard (0...9).contains(priority) else {
                throw APIError.badRequest("Field 'priority' must be between 0 (none) and 9 (low); 1 is high, 5 is medium")
            }
            reminder.priority = priority
        }
        if let completed = draft.completed {
            reminder.isCompleted = completed
        }
        if let raw = draft.url {
            guard let url = URL(string: raw), url.scheme != nil else {
                throw APIError.badRequest("Field 'url' must be an absolute URL")
            }
            reminder.url = url
        }
        if let due = draft.due {
            let units: Set<Calendar.Component> = draft.dueHasTime
                ? [.year, .month, .day, .hour, .minute, .second]
                : [.year, .month, .day]
            reminder.dueDateComponents = Calendar.current.dateComponents(units, from: due)
            // Without an alarm a timed reminder never notifies, which surprises
            // everyone the first time. Match what the Reminders app does.
            if draft.dueHasTime, reminder.alarms?.isEmpty ?? true {
                reminder.addAlarm(EKAlarm(absoluteDate: due))
            }
        }
        if let alarms = draft.alarms {
            reminder.alarms?.forEach { reminder.removeAlarm($0) }
            for date in alarms { reminder.addAlarm(EKAlarm(absoluteDate: date)) }
        }
    }

    static func serialise(reminder: EKReminder) -> [String: Any] {
        [
            "id": reminder.calendarItemIdentifier,
            "title": reminder.title ?? "",
            "notes": JSONValueOrNull(reminder.notes),
            "list": JSONValueOrNull(reminder.calendar?.title),
            "list_id": JSONValueOrNull(reminder.calendar?.calendarIdentifier),
            "completed": reminder.isCompleted,
            "completion_date": DateParsing.formatOptional(reminder.completionDate),
            "due": DateParsing.formatOptional(EventKitService.dueDate(of: reminder)),
            "priority": reminder.priority,
            "url": JSONValueOrNull(reminder.url?.absoluteString),
            "created": DateParsing.formatOptional(reminder.creationDate),
            "last_modified": DateParsing.formatOptional(reminder.lastModifiedDate),
        ]
    }
}
