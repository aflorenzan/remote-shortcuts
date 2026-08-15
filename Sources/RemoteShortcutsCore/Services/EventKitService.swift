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

    public enum Access { case granted, denied, notDetermined, restricted }

    /// macOS 14 split `.authorized` into `.fullAccess` / `.writeOnly`; both the
    /// old and new cases are mapped here so one binary covers macOS 13+.
    public static func authorisationStatus(for entity: EKEntityType) -> Access {
        let status = EKEventStore.authorizationStatus(for: entity)
        if #available(macOS 14.0, *) {
            if status == .fullAccess || status == .writeOnly { return .granted }
        }
        switch status {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
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

    private func requireAccess(_ entity: EKEntityType) throws {
        let service = entity == .event ? "Calendars" : "Reminders"
        switch EventKitService.authorisationStatus(for: entity) {
        case .granted:
            return
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

    private func sync<T>(_ work: @escaping (EKEventStore) throws -> T) throws -> T {
        try queue.sync { try work(store) }
    }

    // MARK: - Calendars

    public func listCalendars(entity: EKEntityType) throws -> [[String: Any]] {
        try requireAccess(entity)
        return try sync { store in
            store.calendars(for: entity).map(EventKitService.serialise(calendar:))
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
            "color": JSONValueOrNull(calendar.color.flatMap(EventKitService.hexString(from:))),
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

    static func hexString(from color: CGColor) -> String? {
        guard let components = color.components, components.count >= 3 else { return nil }
        let r = Int((components[0] * 255).rounded())
        let g = Int((components[1] * 255).rounded())
        let b = Int((components[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
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
            guard let event = store.event(withIdentifier: identifier) else {
                throw APIError.notFound("No event with id '\(identifier)'")
            }
            return EventKitService.serialise(event: event)
        }
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
        try requireAccess(.event)
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
        try requireAccess(.event)
        return try sync { store in
            guard let event = store.event(withIdentifier: identifier) else {
                throw APIError.notFound("No event with id '\(identifier)'")
            }
            guard event.calendar?.allowsContentModifications ?? false else {
                throw APIError.forbidden("Event belongs to a read-only calendar.")
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
            return EventKitService.serialise(event: event)
        }
    }

    public func deleteEvent(identifier: String, span: EKSpan) throws {
        try requireAccess(.event)
        try sync { store in
            guard let event = store.event(withIdentifier: identifier) else {
                throw APIError.notFound("No event with id '\(identifier)'")
            }
            do {
                try store.remove(event, span: span, commit: true)
            } catch {
                throw APIError.upstreamFailure("Calendar rejected the deletion: \(error.localizedDescription)")
            }
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

    static func serialise(event: EKEvent) -> [String: Any] {
        var payload: [String: Any] = [
            "id": JSONValueOrNull(event.eventIdentifier),
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
        try requireAccess(.reminder)
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
        try requireAccess(.reminder)
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
        try requireAccess(.reminder)
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
