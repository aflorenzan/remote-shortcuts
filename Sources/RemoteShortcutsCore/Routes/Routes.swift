import EventKit
import Foundation

/// Wires the HTTP surface onto the services. One file so the whole API is
/// readable top to bottom.
public struct RouteBuilder {
    let configuration: Configuration
    let eventKit: EventKitService
    let notes: NotesService
    let shortcuts: ShortcutsService

    public init(
        configuration: Configuration,
        eventKit: EventKitService,
        notes: NotesService,
        shortcuts: ShortcutsService
    ) {
        self.configuration = configuration
        self.eventKit = eventKit
        self.notes = notes
        self.shortcuts = shortcuts
    }

    public func build() -> Router {
        let router = Router()
        registerMeta(router)
        if configuration.modules.shortcuts { registerShortcuts(router) }
        if configuration.modules.calendars { registerCalendars(router) }
        if configuration.modules.reminders { registerReminders(router) }
        if configuration.modules.notes { registerNotes(router) }
        return router
    }

    // MARK: - Meta

    private func registerMeta(_ router: Router) {
        router.get("/v1/health") { _ in
            .json([
                "status": "ok",
                "version": BuildInfo.version,
                "time": DateParsing.format(Date()),
            ])
        }

        router.get("/v1") { _ in
            .json([
                "name": "remote-shortcuts",
                "version": BuildInfo.version,
                "modules": configuration.modules.asJSON,
                "read_only": configuration.readOnly,
                "endpoints": endpointCatalogue(),
            ])
        }

        router.get("/v1/system/permissions") { _ in
            .json(["permissions": permissionReport()])
        }

        // Raises the macOS prompts inside *this* process.
        //
        // Running `preflight` in a terminal grants the terminal app, because
        // macOS attributes a privacy grant to the responsible process — so it
        // leaves the service with nothing while reporting success. Asking the
        // service to prompt for itself is the only route that grants the
        // service. Authenticated and rate-limited like everything else.
        router.post("/v1/system/permissions/request") { _ in
            Log.info("Raising macOS permission prompts on request")
            let outcome = eventKit.requestAllAccess()
            var payload: [String: Any] = [
                "requested": outcome,
                "permissions": permissionReport(),
            ]
            if outcome.values.contains(where: { ($0 as? String) == "unanswered" }) {
                payload["note"] = "A prompt went unanswered. It appears on the Mac's screen, so somebody has to be at the machine to accept it. Alternatively grant access in System Settings → Privacy & Security."
            }
            return .json(payload)
        }
    }

    /// Query parameters each listing accepts. Kept next to the routes that use
    /// them so adding a parameter and forgetting this cannot pass review.
    static let eventQueryParameters: Set<String> = ["start", "end", "calendars", "q", "limit"]
    static let reminderQueryParameters: Set<String> = [
        "lists", "list", "completed", "due_after", "due_before", "q", "limit",
    ]

    private func endpointCatalogue() -> [String] {
        var endpoints = [
            "GET /v1", "GET /v1/health",
            "GET /v1/system/permissions", "POST /v1/system/permissions/request",
        ]
        if configuration.modules.shortcuts {
            endpoints += ["GET /v1/shortcuts", "POST /v1/shortcuts/run"]
        }
        if configuration.modules.calendars {
            endpoints += [
                "GET /v1/calendars",
                "GET /v1/calendars/events",
                "POST /v1/calendars/events",
                "GET /v1/calendars/events/:id",
                "PATCH /v1/calendars/events/:id",
                "DELETE /v1/calendars/events/:id",
                "GET /v1/diagnostics/event-resolution/:id",
            ]
        }
        if configuration.modules.reminders {
            endpoints += [
                "GET /v1/reminders/lists",
                "GET /v1/reminders",
                "POST /v1/reminders",
                "PATCH /v1/reminders/:id",
                "POST /v1/reminders/:id/complete",
                "DELETE /v1/reminders/:id",
            ]
        }
        if configuration.modules.notes {
            endpoints += [
                "GET /v1/notes/folders",
                "GET /v1/notes",
                "POST /v1/notes",
                "GET /v1/notes/:id",
                "PATCH /v1/notes/:id",
                "DELETE /v1/notes/:id",
            ]
        }
        return endpoints
    }

    func permissionReport() -> [String: Any] {
        func describe(_ access: EventKitService.Access) -> String {
            switch access {
            case .granted: return "granted"
            case .writeOnly: return "write_only"
            case .denied: return "denied"
            case .notDetermined: return "not_determined"
            case .restricted: return "restricted"
            }
        }

        let calendars = eventKit.effectiveAccess(for: .event)
        let reminders = eventKit.effectiveAccess(for: .reminder)

        var report: [String: Any] = [
            "calendars": describe(calendars),
            "reminders": describe(reminders),
            "shortcuts_cli": ShortcutsService.isAvailable() ? "available" : "missing",
            "notes_app": NotesService.isAvailable() ? "available" : "missing",
        ]

        // `not_determined` is the one status a caller cannot act on without
        // knowing what it means, so say it rather than leaving them to guess
        // that TCC has failed.
        if calendars == .notDetermined || reminders == .notDetermined {
            report["note"] = "'not_determined' means this process has not been asked for that permission yet, not that it was refused. Run 'remote-shortcuts preflight' from a terminal to request it."
        }
        if calendars == .writeOnly || reminders == .writeOnly {
            report["note"] = "'write_only' means macOS allows creating items but not reading them. Reads are refused rather than returning empty results. Grant full access in System Settings → Privacy & Security."
        }
        return report
    }

    // MARK: - Shortcuts

    private func registerShortcuts(_ router: Router) {
        router.get("/v1/shortcuts") { request in
            try request.rejectUnknownQuery(allowed: [])
            let items = try shortcuts.list()
            return .json([
                "shortcuts": items,
                "count": items.count,
                "allow_list_active": shortcuts.allowListActive,
            ])
        }

        // Running a shortcut is a POST because it has side effects, even
        // though it reads like a lookup.
        router.post("/v1/shortcuts/run") { request in
            try request.rejectUnknownQuery(allowed: [])
            let body = try request.jsonBody()
            try body.rejectUnknownFields(allowed: RouteBuilder.shortcutFields)
            return try runShortcut(name: try body.nonEmptyString("name"), body: body)
        }

        // Convenience form so an n8n HTTP node can put the name in the URL.
        router.post("/v1/shortcuts/:name/run") { request in
            try request.rejectUnknownQuery(allowed: [])
            let body = (try? request.jsonBody()) ?? JSONBody([:])
            // `name` comes from the path here, so a body `name` would be a
            // second, possibly contradictory source. Reject rather than guess.
            try body.rejectUnknownFields(
                allowed: RouteBuilder.shortcutFields.subtracting(["name"]),
                unsupported: ["name": "the shortcut name comes from the URL on this endpoint. Use POST /v1/shortcuts/run to pass it in the body."]
            )
            return try runShortcut(name: try request.parameter("name"), body: body)
        }
    }

    private func runShortcut(name: String, body: JSONBody) throws -> HTTPResponse {
        // `input` accepts either a string or any JSON value; objects and arrays
        // are re-encoded so the shortcut receives valid JSON text.
        var input: String?
        if body.has("input") {
            if let text = body.raw["input"] as? String {
                input = text
            } else if let value = body.raw["input"] {
                input = String(data: try JSON.encode(value), encoding: .utf8)
            }
        }

        let result = try shortcuts.run(name: name, input: input, timeout: try body.optionalDouble("timeout"))

        var payload: [String: Any] = [
            "shortcut": result.name,
            "output": result.output,
            "duration_seconds": result.durationSeconds,
        ]
        if result.outputIsJSON, let decoded = ShortcutsService.decodeJSONOutput(result.output) {
            payload["output_json"] = decoded
        }
        return .json(payload)
    }

    // MARK: - Accepted fields
    //
    // Anything not listed here is rejected with a 400 rather than dropped.
    // A field name that is merely recognisable — `attendees` — gets an
    // explanation instead of a bare "unknown".

    private static let eventCreateFields: Set<String> = [
        "title", "start", "end", "all_day", "location", "notes", "url",
        "calendar", "time_zone", "availability", "alarms_minutes_before",
    ]

    /// Only the update path reads `span`. Sharing one set with create would
    /// accept and ignore it there — the very bug this validation removes.
    private static let eventUpdateFields: Set<String> = eventCreateFields.union(["span"])

    /// Fields rejected on create that ARE valid elsewhere. Saying only
    /// "unknown" leaves the caller to guess; naming the endpoint that takes it
    /// is the difference between a dead end and a fix.
    private static let misplacedCreateFields: [String: String] = [
        "span": "'span' selects which occurrences an edit affects, so it only applies to editing: in the body of PATCH /v1/calendars/events/:id, or in the query of DELETE /v1/calendars/events/:id (which has no body). Not to creating an event.",
    ]

    private static let unsupportedEventFields: [String: String] = [
        "attendees": "EventKit exposes attendees as read-only, so invitees cannot be set through this API. Create the event and invite people from Calendar, or use a shortcut.",
        "organizer": "EventKit exposes the organizer as read-only.",
        "recurrence": "Recurrence rules cannot be set through this API yet. Create the series in Calendar and edit occurrences here.",
    ]

    private static let reminderFields: Set<String> = [
        "title", "notes", "list", "due", "priority", "completed", "url",
    ]

    private static let noteCreateFields: Set<String> = ["title", "body", "format", "folder"]
    private static let noteUpdateFields: Set<String> = ["body", "append", "prepend", "format"]
    private static let shortcutFields: Set<String> = ["name", "input", "timeout"]

    // MARK: - Calendars

    private func registerCalendars(_ router: Router) {
        router.get("/v1/calendars") { request in
            try request.rejectUnknownQuery(allowed: [])
            let calendars = try eventKit.listCalendars(entity: .event)
            return .json(["calendars": calendars, "count": calendars.count])
        }

        router.get("/v1/calendars/events") { request in
            try request.rejectUnknownQuery(allowed: RouteBuilder.eventQueryParameters)
            // Default window: today through a week out — the range an
            // automation asks for when it does not say.
            let start = try request.queryDate("start") ?? Calendar.current.startOfDay(for: Date())
            let end = try request.queryDate("end") ?? start.addingTimeInterval(7 * 24 * 3600)
            let query = EventKitService.EventQuery(
                start: start,
                end: end,
                calendars: request.queryList("calendars"),
                search: request.query["q"],
                limit: min(try request.queryInt("limit") ?? 250, 1000)
            )
            let events = try eventKit.events(matching: query)
            return .json([
                "events": events,
                "count": events.count,
                "range": ["start": DateParsing.format(start), "end": DateParsing.format(end)],
            ])
        }

        router.get("/v1/calendars/events/:id") { request in
            try request.rejectUnknownQuery(allowed: [])
            return .json(["event": try eventKit.event(withIdentifier: try request.parameter("id"))])
        }

        router.post("/v1/calendars/events") { request in
            try request.rejectUnknownQuery(allowed: [])
            let body = try request.jsonBody()
            try body.rejectUnknownFields(
                allowed: RouteBuilder.eventCreateFields,
                unsupported: RouteBuilder.unsupportedEventFields
                    .merging(RouteBuilder.misplacedCreateFields) { existing, _ in existing }
            )
            var draft = EventKitService.EventDraft()
            draft.title = try body.nonEmptyString("title")
            draft.start = try body.date("start")
            draft.end = try body.optionalDate("end")
            try applyCommonEventFields(&draft, from: body)
            return .json(["event": try eventKit.createEvent(draft)], status: .created)
        }

        router.patch("/v1/calendars/events/:id") { request in
            // `span` is read from the body here, so accepting it in the query
            // was accepting a parameter nobody reads.
            //
            // `?span=future_events` returned 200 having quietly applied
            // `this_event` — which on a recurring series changes exactly one
            // occurrence, the same symptom as a broken `future_events`. Two
            // rounds of verification chased that phantom, a working safety net
            // was rewritten to catch it, and three false statements went into
            // docs/API.md before anyone noticed the request had never asked
            // for what it appeared to ask for.
            if request.query["span"] != nil {
                throw APIError.badRequest(
                    "'span' goes in the request body for PATCH, not the query string: send {\"span\": \"future_events\"}. "
                        + "The query form belongs to DELETE, which has no body. Accepting it here would have silently applied 'this_event'."
                )
            }
            try request.rejectUnknownQuery(allowed: [])
            let body = try request.jsonBody()
            try body.rejectUnknownFields(
                allowed: RouteBuilder.eventUpdateFields,
                unsupported: RouteBuilder.unsupportedEventFields
            )
            var draft = EventKitService.EventDraft()
            draft.title = try body.optionalString("title")
            draft.start = try body.optionalDate("start")
            draft.end = try body.optionalDate("end")
            try applyCommonEventFields(&draft, from: body)
            let event = try eventKit.updateEvent(
                identifier: try request.parameter("id"),
                draft: draft,
                span: try span(from: body.raw["span"] as? String)
            )
            return .json(["event": event])
        }

        router.delete("/v1/calendars/events/:id") { request in
            try request.rejectUnknownQuery(allowed: ["span"])
            try eventKit.deleteEvent(
                identifier: try request.parameter("id"),
                span: try span(from: request.query["span"])
            )
            return .json(["deleted": true])
        }

        // Read-only, authenticated like everything else, and deliberately named
        // as a diagnostic rather than dressed up as API surface.
        //
        // It answers a question that cannot be answered from outside: what
        // `event(withIdentifier:)` returns for a composite id. All three
        // possible answers — the occurrence, the series master, nil — make
        // `resolve` return the same occurrence, so no external experiment can
        // separate them, and only a process holding the calendar grant can
        // look. This is that process.
        router.get("/v1/diagnostics/event-resolution/:id") { request in
            try request.rejectUnknownQuery(allowed: [])
            return .json(try eventKit.diagnoseResolution(of: try request.parameter("id")))
        }
    }

    private func applyCommonEventFields(_ draft: inout EventKitService.EventDraft, from body: JSONBody) throws {
        draft.isAllDay = try body.optionalBool("all_day")
        draft.location = try body.optionalString("location")
        draft.notes = try body.optionalString("notes")
        draft.url = try body.optionalString("url")
        draft.calendar = try body.optionalString("calendar")
        draft.timeZone = try body.optionalString("time_zone")
        draft.availability = try body.optionalString("availability")
        if body.has("alarms_minutes_before") {
            guard let raw = body.raw["alarms_minutes_before"] as? [Any] else {
                throw APIError.badRequest("Field 'alarms_minutes_before' must be an array of numbers")
            }
            draft.alarms = try raw.map {
                guard let number = $0 as? NSNumber else {
                    throw APIError.badRequest("Field 'alarms_minutes_before' must contain only numbers")
                }
                return number.intValue
            }
        }
    }

    /// Recurring events need to say whether an edit hits one occurrence or the
    /// whole series. Defaulting to `this_event` is the conservative choice.
    private func span(from raw: String?) throws -> EKSpan {
        switch raw?.lowercased() {
        case nil, "", "this_event", "this": return .thisEvent
        case "future_events", "future": return .futureEvents
        default: throw APIError.badRequest("'span' must be 'this_event' or 'future_events'")
        }
    }

    // MARK: - Reminders

    private func registerReminders(_ router: Router) {
        router.get("/v1/reminders/lists") { request in
            try request.rejectUnknownQuery(allowed: [])
            let lists = try eventKit.listCalendars(entity: .reminder)
            return .json(["lists": lists, "count": lists.count])
        }

        router.get("/v1/reminders") { request in
            try request.rejectUnknownQuery(allowed: RouteBuilder.reminderQueryParameters)
            let query = EventKitService.ReminderQuery(
                lists: request.queryList("lists") ?? request.queryList("list"),
                completed: try request.queryBool("completed"),
                dueAfter: try request.queryDate("due_after"),
                dueBefore: try request.queryDate("due_before"),
                search: request.query["q"],
                limit: min(try request.queryInt("limit") ?? 250, 1000)
            )
            let reminders = try eventKit.reminders(matching: query)
            return .json(["reminders": reminders, "count": reminders.count])
        }

        router.post("/v1/reminders") { request in
            try request.rejectUnknownQuery(allowed: [])
            let body = try request.jsonBody()
            try body.rejectUnknownFields(allowed: RouteBuilder.reminderFields)
            var draft = EventKitService.ReminderDraft()
            draft.title = try body.nonEmptyString("title")
            try applyCommonReminderFields(&draft, from: body)
            return .json(["reminder": try eventKit.createReminder(draft)], status: .created)
        }

        router.patch("/v1/reminders/:id") { request in
            try request.rejectUnknownQuery(allowed: [])
            let body = try request.jsonBody()
            try body.rejectUnknownFields(allowed: RouteBuilder.reminderFields)
            var draft = EventKitService.ReminderDraft()
            draft.title = try body.optionalString("title")
            try applyCommonReminderFields(&draft, from: body)
            return .json(["reminder": try eventKit.updateReminder(identifier: try request.parameter("id"), draft: draft)])
        }

        // Completing is the single most common automation, so it gets a verb
        // of its own rather than requiring a PATCH body.
        router.post("/v1/reminders/:id/complete") { request in
            try request.rejectUnknownQuery(allowed: [])
            var draft = EventKitService.ReminderDraft()
            draft.completed = true
            return .json(["reminder": try eventKit.updateReminder(identifier: try request.parameter("id"), draft: draft)])
        }

        router.delete("/v1/reminders/:id") { request in
            try request.rejectUnknownQuery(allowed: [])
            try eventKit.deleteReminder(identifier: try request.parameter("id"))
            return .json(["deleted": true])
        }
    }

    private func applyCommonReminderFields(_ draft: inout EventKitService.ReminderDraft, from body: JSONBody) throws {
        draft.notes = try body.optionalString("notes")
        draft.list = try body.optionalString("list")
        draft.due = try body.optionalDate("due")
        draft.priority = try body.optionalInt("priority")
        draft.completed = try body.optionalBool("completed")
        draft.url = try body.optionalString("url")
        // A bare `yyyy-MM-dd` due date means "that day", with no alarm time.
        if let raw = try body.optionalString("due") {
            draft.dueHasTime = raw.contains("T") || raw.contains(":")
        }
    }

    // MARK: - Notes

    private func registerNotes(_ router: Router) {
        router.get("/v1/notes/folders") { request in
            try request.rejectUnknownQuery(allowed: [])
            let folders = try notes.listFolders()
            return .json(["folders": folders, "count": folders.count])
        }

        router.get("/v1/notes") { request in
            try request.rejectUnknownQuery(allowed: ["folder", "q", "limit", "include_body"])
            let includeBody = try request.queryBool("include_body") ?? false
            let requestedLimit = try request.queryInt("limit")
            var limit = min(requestedLimit ?? 50, 500)
            var clamped = false

            // Bound the work before doing it, not after.
            //
            // The 8 MB output cap cannot be enforced early: `osascript` returns
            // its whole result at the end, so nothing is over the limit until
            // everything has already been computed. A 50-note body request
            // measured 17 seconds before its 413.
            //
            // An explicit over-cap `limit` is refused, because the caller asked
            // for something this server will not do. An unspecified one is
            // clamped instead — the default of 50 is ours, not theirs, and
            // failing the simplest possible call (`?include_body=true`) would
            // be a poor way to communicate a policy. The response says when it
            // clamped, so a short list is never mistaken for a short library.
            if includeBody, limit > configuration.maxNotesWithBody {
                guard requestedLimit == nil else {
                    throw APIError.payloadTooLarge(
                        "Asking for \(limit) note bodies at once will exceed the 8 MB this server buffers, and the failure would take many seconds to discover, so it is refused now. Use 'limit' of \(configuration.maxNotesWithBody) or fewer with 'include_body', drop 'include_body' to list more, or raise 'max_notes_with_body' in \(ConfigPaths.configFile.path) if your notes are short."
                    )
                }
                limit = configuration.maxNotesWithBody
                clamped = true
            }

            let items = try notes.listNotes(
                folder: request.query["folder"],
                search: request.query["q"],
                limit: limit,
                includeBody: includeBody
            )
            var payload: [String: Any] = ["notes": items, "count": items.count]
            if clamped {
                payload["limit_applied"] = limit
                payload["note"] = "Limited to \(limit) notes because 'include_body' was set; there may be more. Ask for them in pages, or raise 'max_notes_with_body' in the config."
            }
            let omitted = items.filter { $0["body_omitted"] != nil }.count
            if omitted > 0 {
                payload["bodies_omitted"] = omitted
            }
            return .json(payload)
        }

        router.get("/v1/notes/:id") { request in
            // `include_body` is honoured here too. It used not to be, and a
            // note of embedded images measured at 17.8 MB was consequently
            // unreachable: the reply blew the 8 MB cap, so the request failed
            // with 413 and returned no title, no folder and no dates either —
            // and the error advised fetching bodies "one note at a time",
            // which is exactly what this endpoint does.
            try request.rejectUnknownQuery(allowed: ["include_body"])
            let includeBody = try request.queryBool("include_body") ?? true
            return .json([
                "note": try notes.note(
                    id: try request.parameter("id"),
                    includeBody: includeBody
                ),
            ])
        }

        router.post("/v1/notes") { request in
            try request.rejectUnknownQuery(allowed: [])
            let body = try request.jsonBody()
            try body.rejectUnknownFields(allowed: RouteBuilder.noteCreateFields)
            let format = try body.optionalString("format")?.lowercased() ?? "text"
            guard ["text", "html"].contains(format) else {
                throw APIError.badRequest("Field 'format' must be 'text' or 'html'")
            }
            let note = try notes.createNote(
                title: try body.nonEmptyString("title"),
                body: try body.optionalString("body") ?? "",
                folder: try body.optionalString("folder"),
                isHTML: format == "html"
            )
            return .json(["note": note], status: .created)
        }

        router.patch("/v1/notes/:id") { request in
            try request.rejectUnknownQuery(allowed: [])
            let body = try request.jsonBody()
            try body.rejectUnknownFields(allowed: RouteBuilder.noteUpdateFields)
            var edit = NotesService.NoteEdit()
            edit.body = try body.optionalString("body")
            edit.append = try body.optionalString("append")
            edit.prepend = try body.optionalString("prepend")
            let format = try body.optionalString("format")?.lowercased() ?? "text"
            guard ["text", "html"].contains(format) else {
                throw APIError.badRequest("Field 'format' must be 'text' or 'html'")
            }
            edit.isHTML = format == "html"

            guard edit.body != nil || edit.append != nil || edit.prepend != nil else {
                throw APIError.badRequest("Provide at least one of 'body', 'append' or 'prepend'")
            }
            return .json(["note": try notes.updateNote(id: try request.parameter("id"), edit: edit)])
        }

        router.delete("/v1/notes/:id") { request in
            try request.rejectUnknownQuery(allowed: [])
            try notes.deleteNote(id: try request.parameter("id"))
            return .json(["deleted": true])
        }
    }
}

public enum BuildInfo {
    public static let version = "1.1.0"
}
