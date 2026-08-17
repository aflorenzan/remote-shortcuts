import Foundation

/// Apple Notes access.
///
/// Notes has no public Swift/Obj-C SDK — the supported automation surface is
/// its AppleScript dictionary, driven here through `/usr/bin/osascript`.
///
/// SECURITY — the single most important property of this file: **no user data
/// is ever interpolated into a script**. Every script below is a compile-time
/// constant with an `on run argv` entry point, and caller values arrive as
/// process arguments. That makes AppleScript injection structurally impossible
/// rather than something we try to escape our way out of.
///
/// Records come back delimited by ASCII US (31) between fields and RS (30)
/// between records. Those control characters cannot occur in Notes content,
/// which keeps parsing unambiguous without asking AppleScript to emit JSON.
public final class NotesService: @unchecked Sendable {
    private static let osascript = "/usr/bin/osascript"
    private static let fieldSeparator = "\u{001F}"
    private static let recordSeparator = "\u{001E}"

    /// Serialised: AppleScript sends Apple Events to a single-threaded app, so
    /// firing several at once just queues them badly.
    private let queue = DispatchQueue(label: "com.remoteshortcuts.notes")
    private let timeout: Double

    public init(timeout: Double = 30) {
        self.timeout = timeout
    }

    // MARK: - Script runner

    private func run(_ script: String, _ arguments: [String]) throws -> String {
        try queue.sync {
            let result: ProcessRunner.Result
            do {
                // Script via stdin ("-"), user data strictly via argv.
                result = try ProcessRunner.run(
                    executable: NotesService.osascript,
                    arguments: ["-"] + arguments,
                    standardInput: Data(script.utf8),
                    timeout: timeout
                )
            } catch let error as ProcessRunner.RunError {
                if case .timedOut = error {
                    throw APIError.timeout("Apple Notes did not respond within \(Int(timeout)) seconds. It may be showing a dialog or syncing.")
                }
                throw APIError.upstreamFailure(error.description)
            }

            guard result.exitCode == 0 else {
                throw NotesService.translate(stderr: result.stderrString, exitCode: result.exitCode)
            }

            // The scripts fall back to per-note property access when the bulk
            // form fails. That is correct but much slower, so surface it rather
            // than letting the API quietly get sluggish.
            if result.stderrString.contains("RS_BULK_FALLBACK") {
                Log.warn("Apple Notes bulk property fetch failed; using the slow per-note path. \(NotesService.fallbackDetail(result.stderrString))")
            }

            return result.stdoutString.trimmingCharacters(in: .newlines)
        }
    }

    /// Turns AppleScript's error text into an actionable HTTP error.
    static func translate(stderr: String, exitCode: Int32) -> APIError {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = message.lowercased()

        if lowered.contains("-1743") || lowered.contains("not allowed to send apple events") || lowered.contains("not authorized") {
            return .permissionDenied(
                service: "Automation",
                detail: "This Mac has not allowed Remote Shortcuts to control Apple Notes."
            )
        }
        if lowered.contains("-600") || lowered.contains("application isn't running") {
            return .upstreamFailure("Apple Notes is not running and could not be launched.")
        }
        // Only our own sentinel means "the caller asked for something that is
        // not there". A bare -1728 is AppleScript failing to get a property,
        // which is a fault on our side.
        //
        // These used to share the 404 mapping, and that is precisely how a
        // total failure of `GET /v1/notes` — every non-empty folder erroring
        // out — was mistaken for "folder not found" for as long as it was.
        // Report the real message so the next one is diagnosable.
        if message.contains("REMOTE_SHORTCUTS_NOT_FOUND") {
            return .notFound("No matching note or folder")
        }
        if lowered.contains("-1728") {
            return .upstreamFailure(
                "Apple Notes could not read a property (-1728). This is a fault in the script, not a missing item: \(message.isEmpty ? "no detail" : message)"
            )
        }
        return .upstreamFailure("Apple Notes returned an error (exit \(exitCode)): \(message.isEmpty ? "no detail" : message)")
    }

    /// Pulls the AppleScript error out of the fallback log line, for the warning.
    static func fallbackDetail(_ stderr: String) -> String {
        guard let line = stderr.components(separatedBy: .newlines).first(where: { $0.contains("RS_BULK_FALLBACK") }) else {
            return ""
        }
        return line.replacingOccurrences(of: "RS_BULK_FALLBACK", with: "").trimmingCharacters(in: .whitespaces)
    }

    private static func parseRecords(_ output: String) -> [[String]] {
        guard !output.isEmpty else { return [] }
        return output
            .components(separatedBy: recordSeparator)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { $0.components(separatedBy: fieldSeparator) }
    }

    private static func field(_ record: [String], _ index: Int) -> String {
        index < record.count ? record[index] : ""
    }

    // MARK: - Availability

    public static func isAvailable() -> Bool {
        FileManager.default.fileExists(atPath: "/System/Applications/Notes.app")
            || FileManager.default.fileExists(atPath: "/Applications/Notes.app")
    }

    /// Cheap round-trip used by `doctor` and `preflight` to trigger (and
    /// verify) the Automation permission prompt.
    public func probe() throws -> Int {
        let output = try run(Scripts.countFolders, [])
        return Int(output.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    // MARK: - Folders

    public func listFolders() throws -> [[String: Any]] {
        let output = try run(Scripts.listFolders, [])
        return NotesService.parseRecords(output).map { record in
            [
                "id": NotesService.field(record, 0),
                "name": NotesService.field(record, 1),
                "note_count": Int(NotesService.field(record, 2)) ?? 0,
                "account": NotesService.field(record, 3),
            ]
        }
    }

    // MARK: - Notes

    public func listNotes(folder: String?, search: String?, limit: Int, includeBody: Bool) throws -> [[String: Any]] {
        let output = try run(
            Scripts.listNotes,
            [folder ?? "", search ?? "", String(max(1, min(limit, 500))), includeBody ? "1" : "0"]
        )
        return NotesService.parseRecords(output).map { record in
            var payload: [String: Any] = [
                "id": NotesService.field(record, 0),
                "title": NotesService.field(record, 1),
                "folder": NotesService.field(record, 2),
                "created": NotesService.appleDate(NotesService.field(record, 3)),
                "modified": NotesService.appleDate(NotesService.field(record, 4)),
            ]
            if includeBody {
                payload["body"] = NotesService.field(record, 5)
            }
            return payload
        }
    }

    public func note(id: String) throws -> [String: Any] {
        let output = try run(Scripts.getNote, [id])
        guard let record = NotesService.parseRecords(output).first else {
            throw APIError.notFound("No note with id '\(id)'")
        }
        return [
            "id": NotesService.field(record, 0),
            "title": NotesService.field(record, 1),
            "folder": NotesService.field(record, 2),
            "created": NotesService.appleDate(NotesService.field(record, 3)),
            "modified": NotesService.appleDate(NotesService.field(record, 4)),
            "body": NotesService.field(record, 5),
            "plain_text": NotesService.field(record, 6),
        ]
    }

    /// `body` is HTML — Notes stores rich text and renders the markup it is
    /// given. Callers sending plain text get it escaped and wrapped first.
    public func createNote(title: String, body: String, folder: String?, isHTML: Bool) throws -> [String: Any] {
        let html = isHTML ? body : NotesService.plainTextToHTML(body)
        // Notes derives the visible title from the first line of the body, so
        // the title is prepended as a heading rather than set as a property.
        let document = "<h1>\(NotesService.escapeHTML(title))</h1>\n\(html)"
        let output = try run(Scripts.createNote, [title, document, folder ?? ""])
        let identifier = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else {
            throw APIError.upstreamFailure("Apple Notes did not return an id for the new note")
        }
        return try note(id: identifier)
    }

    public struct NoteEdit {
        public var body: String?
        public var append: String?
        public var prepend: String?
        public var isHTML: Bool = true
        public init() {}
    }

    public func updateNote(id: String, edit: NoteEdit) throws -> [String: Any] {
        func markup(_ value: String?) -> String {
            guard let value else { return "" }
            return edit.isHTML ? value : NotesService.plainTextToHTML(value)
        }

        if let replacement = edit.body {
            _ = try run(Scripts.replaceBody, [id, markup(replacement)])
        }
        if edit.append != nil || edit.prepend != nil {
            _ = try run(Scripts.appendBody, [id, markup(edit.append), markup(edit.prepend)])
        }
        return try note(id: id)
    }

    public func deleteNote(id: String) throws {
        _ = try run(Scripts.deleteNote, [id])
    }

    // MARK: - Conversions

    static func escapeHTML(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func plainTextToHTML(_ raw: String) -> String {
        raw.components(separatedBy: .newlines)
            .map { "<div>\(escapeHTML($0))</div>" }
            .joined()
    }

    /// AppleScript emits dates as ISO-8601 (we ask for it explicitly), but a
    /// missing date comes back empty.
    static func appleDate(_ raw: String) -> Any {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let date = DateParsing.parse(trimmed) else { return NSNull() }
        return DateParsing.format(date)
    }
}

// MARK: - Scripts

/// Every script here is a constant. Values reach them through `argv` only.// MARK: - Scripts

/// Every script here is a constant. Values reach them through `argv` only.
///
/// ## The specifier rule
///
/// The single thing to understand before editing these: **`repeat with f in
/// (folders whose name is X)` yields evaluated references, not object
/// specifiers.** Ask such a reference for `notes of f` and AppleScript hands
/// back a *list* of note references; ask that list for `id of …` and it fails
/// with -1728, because a list has no `id` property.
///
/// That is what broke `GET /v1/notes` for every folder that actually contained
/// notes — empty folders returned 200 because the bulk fetch was skipped.
///
/// So these scripts address folders by index (`folder i`), which stays a real
/// specifier, and `notes of folder i` is therefore a plural specifier that
/// supports bulk property access.
///
/// Each bulk fetch is nonetheless wrapped in a `try` that falls back to
/// per-note access. It is slower, but a slow correct answer beats a 404, and
/// the fallback logs `RS_BULK_FALLBACK` to stderr so the degradation is
/// visible rather than silent.
private enum Scripts {
    /// Shared prelude.
    ///
    /// Handlers only. A script with an explicit `on run` handler may not also
    /// carry loose top-level statements, so the separators are properties.
    ///
    /// `isoDate` exists because AppleScript renders dates in the user's locale
    /// ("Friday, 15 August 2026 at 09:00"), which no date parser should have to
    /// guess at.
    private static let prelude = """
    property fieldSep : (character id 31)
    property recordSep : (character id 30)

    on isoDate(theDate)
        if theDate is missing value then return ""
        set y to (year of theDate)
        set m to ((month of theDate) as integer)
        set d to (day of theDate)
        set hh to (hours of theDate)
        set mm to (minutes of theDate)
        set ss to (seconds of theDate)
        return (my pad(y, 4)) & "-" & (my pad(m, 2)) & "-" & (my pad(d, 2)) & "T" & ¬
            (my pad(hh, 2)) & ":" & (my pad(mm, 2)) & ":" & (my pad(ss, 2))
    end isoDate

    on pad(n, width)
        set s to ((n as integer) as text)
        repeat while (count of s) < width
            set s to "0" & s
        end repeat
        return s
    end pad
    """

    static let countFolders = """
    \(prelude)
    on run argv
        tell application "Notes" to return ((count of folders) as text)
    end run
    """

    /// Enumerates folders per account.
    ///
    /// `container of folder i` fails on nested folders, and the `try` around it
    /// swallowed the error — which is why 35 of 43 folders reported
    /// `account: ""`, exactly the nested ones. Even when it does resolve, a
    /// nested folder's container is its *parent folder*, not the account, so it
    /// was the wrong value anyway.
    ///
    /// `folders of account a` returns every folder including nested ones, so the
    /// account is known without walking a container chain. Verified on a real
    /// Mac: 43 folders, all with an account, and faster than the old form.
    static let listFolders = """
    \(prelude)
    on run argv
        set output to ""
        tell application "Notes"
            set accountCount to (count of accounts)
        end tell

        repeat with a from 1 to accountCount
            tell application "Notes"
                set accountName to ((name of account a) as text)
                set folderCount to (count of folders of account a)
            end tell

            repeat with i from 1 to folderCount
                tell application "Notes"
                    set folderID to ((id of folder i of account a) as text)
                    set folderName to ((name of folder i of account a) as text)
                    set noteTotal to ((count of notes of folder i of account a) as text)
                end tell
                set output to output & folderID & fieldSep & folderName & fieldSep & ¬
                    noteTotal & fieldSep & accountName & recordSep
            end repeat
        end repeat
        return output
    end run
    """

    /// argv: 1 folder filter (may be ""), 2 search text (may be ""),
    ///       3 limit, 4 "1" to include the HTML body.
    ///
    /// ## `a reference to` is the load-bearing part
    ///
    /// `set candidates to notes of folder i` *materialises* the plural into a
    /// list of individual references, and AppleScript will not map a property
    /// over a list — `id of candidates` then fails with
    /// "Can't get id of {note id …, note id …}" (-1728).
    ///
    /// Addressing the folder by index was necessary but not sufficient; what
    /// broke the bulk fetch was assigning the plural to a variable.
    /// `a reference to` keeps it a specifier. Measured on a real 389-note
    /// folder: without it the bulk failed and the request timed out past 30s;
    /// with it, 389 ids in 0.30s.
    ///
    /// ## Bodies are requested separately
    ///
    /// `body of candidates` in bulk works to at least 55 notes and fails at 389
    /// with -1741 — a limit on the *size* of the Apple Event reply, not the
    /// count. So bodies get their own `try`: a failure there degrades only the
    /// bodies, and the per-note fallback walks just the notes about to be
    /// emitted, so its cost is bounded by `limit` rather than by folder size.
    /// Bodies are opt-in (`include_body`) and `limit` defaults to 50, which
    /// keeps the common case comfortably inside the bulk path.
    static let listNotes = """
    \(prelude)

    on run argv
        set folderFilter to item 1 of argv
        set searchText to item 2 of argv
        set maxCount to (item 3 of argv) as integer
        set wantBody to ((item 4 of argv) is "1")

        set output to ""
        set emitted to 0
        set matchedFolder to false

        tell application "Notes"
            set accountCount to (count of accounts)
        end tell

        repeat with a from 1 to accountCount
            if emitted < maxCount then
                tell application "Notes"
                    set folderCount to (count of folders of account a)
                    set folderNames to {}
                    if folderCount > 0 then set folderNames to (name of folders of account a)
                end tell

                repeat with i from 1 to folderCount
                    if emitted < maxCount then
                        set folderName to ((item i of folderNames) as text)

                        if (folderFilter is "") or (folderName is folderFilter) then
                            set matchedFolder to true

                            tell application "Notes"
                                if searchText is not "" then
                                    set candidates to a reference to (notes of folder i of account a whose name contains searchText)
                                else
                                    set candidates to a reference to (notes of folder i of account a)
                                end if
                                set noteCount to (count of candidates)
                            end tell

                            if noteCount > 0 then
                                set idList to {}
                                set nameList to {}
                                set createdList to {}
                                set modifiedList to {}

                                try
                                    tell application "Notes"
                                        set idList to (id of candidates)
                                        set nameList to (name of candidates)
                                        set createdList to (creation date of candidates)
                                        set modifiedList to (modification date of candidates)
                                    end tell
                                on error bulkError
                                    log "RS_BULK_FALLBACK properties: " & bulkError
                                    set idList to {}
                                    set nameList to {}
                                    set createdList to {}
                                    set modifiedList to {}
                                    tell application "Notes"
                                        repeat with n in candidates
                                            set end of idList to ((id of n) as text)
                                            set end of nameList to ((name of n) as text)
                                            set end of createdList to (creation date of n)
                                            set end of modifiedList to (modification date of n)
                                        end repeat
                                    end tell
                                end try

                                set wanted to (count of idList)
                                if (emitted + wanted) > maxCount then set wanted to (maxCount - emitted)

                                -- Bodies are asked for separately, with their own
                                -- try, so an oversized reply (-1741, a limit on
                                -- Apple Event *size* — reproduced at 389 notes,
                                -- fine at 55) cannot drag the ids and dates onto
                                -- the slow path with it.
                                --
                                -- The per-note fallback walks only the notes
                                -- about to be emitted, so its cost is bounded by
                                -- `limit` rather than by the size of the folder.
                                set bodyList to {}
                                if wantBody and wanted > 0 then
                                    try
                                        tell application "Notes"
                                            set bodyList to (body of candidates)
                                        end tell
                                    on error bodyError
                                        log "RS_BULK_FALLBACK bodies: " & bodyError
                                        set bodyList to {}
                                        tell application "Notes"
                                            repeat with k from 1 to wanted
                                                set end of bodyList to ((body of (item k of candidates)) as text)
                                            end repeat
                                        end tell
                                    end try
                                end if

                                repeat with k from 1 to wanted
                                    set bodyField to ""
                                    if wantBody and (k ≤ (count of bodyList)) then
                                        set bodyField to ((item k of bodyList) as text)
                                    end if
                                    set output to output & ((item k of idList) as text) & fieldSep & ¬
                                        ((item k of nameList) as text) & fieldSep & folderName & fieldSep & ¬
                                        my isoDate(item k of createdList) & fieldSep & ¬
                                        my isoDate(item k of modifiedList) & fieldSep & bodyField & recordSep
                                    set emitted to emitted + 1
                                end repeat
                            end if
                        end if
                    end if
                end repeat
            end if
        end repeat

        if (folderFilter is not "") and (matchedFolder is false) then
            error "REMOTE_SHORTCUTS_NOT_FOUND" number -1728
        end if
        return output
    end run
    """

    /// argv: 1 note id.
    ///
    /// The folder is found by scanning, not by reading `container`.
    ///
    /// `container of <note>` fails the same way `container of folder i` does, and
    /// the `try` around it swallowed the error — which is why `POST /v1/notes`
    /// and `GET /v1/notes/:id` reported `folder: ""` while the list endpoint,
    /// which knows the folder because it iterated to it, reported it correctly.
    ///
    /// Scanning is affordable now that ids come back in bulk: one request per
    /// folder, and it stops at the first match.
    static let getNote = """
    \(prelude)
    on run argv
        set noteID to item 1 of argv

        tell application "Notes"
            set resolved to false
            try
                set theNote to note id noteID
                set probe to (name of theNote)
                set resolved to true
            end try

            if resolved is false then
                set matches to (notes whose id is noteID)
                if (count of matches) is 0 then
                    error "REMOTE_SHORTCUTS_NOT_FOUND" number -1728
                end if
                set theNote to item 1 of matches
            end if

            set noteName to ((name of theNote) as text)
            set noteBody to ((body of theNote) as text)
            set notePlain to ((plaintext of theNote) as text)
            set createdAt to (creation date of theNote)
            set modifiedAt to (modification date of theNote)
        end tell

        set folderName to my folderContaining(noteID)

        return noteID & fieldSep & noteName & fieldSep & folderName & fieldSep & ¬
            my isoDate(createdAt) & fieldSep & my isoDate(modifiedAt) & fieldSep & ¬
            noteBody & fieldSep & notePlain & recordSep
    end run

    on folderContaining(noteID)
        tell application "Notes"
            set accountCount to (count of accounts)
        end tell

        repeat with a from 1 to accountCount
            tell application "Notes"
                set folderCount to (count of folders of account a)
                set folderNames to {}
                if folderCount > 0 then set folderNames to (name of folders of account a)
            end tell

            repeat with i from 1 to folderCount
                tell application "Notes"
                    set idList to {}
                    try
                        set idList to (id of (a reference to (notes of folder i of account a)))
                    end try
                end tell
                repeat with candidateID in idList
                    if ((candidateID as text) is noteID) then
                        return ((item i of folderNames) as text)
                    end if
                end repeat
            end repeat
        end repeat

        return ""
    end folderContaining
    """

    /// argv: 1 title (unused by Notes but kept for clarity), 2 HTML body,
    ///       3 folder name (may be "" for the default folder).
    static let createNote = """
    \(prelude)
    on run argv
        set noteBody to item 2 of argv
        set folderName to item 3 of argv

        tell application "Notes"
            if folderName is not "" then
                set targetIndex to 0
                set folderCount to (count of folders)
                set folderNames to {}
                if folderCount > 0 then set folderNames to (name of folders)
                repeat with i from 1 to folderCount
                    if ((item i of folderNames) as text) is folderName then
                        set targetIndex to i
                        exit repeat
                    end if
                end repeat
                if targetIndex is 0 then
                    error "REMOTE_SHORTCUTS_NOT_FOUND" number -1728
                end if
                set newNote to make new note at folder targetIndex with properties {body:noteBody}
            else
                set newNote to make new note with properties {body:noteBody}
            end if
            return ((id of newNote) as text)
        end tell
    end run
    """

    /// argv: 1 note id, 2 replacement HTML.
    static let replaceBody = """
    \(prelude)
    on run argv
        set noteID to item 1 of argv
        set newBody to item 2 of argv
        tell application "Notes"
            set body of (my resolveNote(noteID)) to newBody
        end tell
        return "ok"
    end run

    on resolveNote(noteID)
        tell application "Notes"
            try
                set theNote to note id noteID
                set probe to (name of theNote)
                return theNote
            end try
            set matches to (notes whose id is noteID)
            if (count of matches) is 0 then
                error "REMOTE_SHORTCUTS_NOT_FOUND" number -1728
            end if
            return item 1 of matches
        end tell
    end resolveNote
    """

    /// argv: 1 note id, 2 HTML to append (may be ""), 3 HTML to prepend (may be "").
    static let appendBody = """
    \(prelude)
    on run argv
        set noteID to item 1 of argv
        set appendHTML to item 2 of argv
        set prependHTML to item 3 of argv
        tell application "Notes"
            set n to my resolveNote(noteID)
            set current to ((body of n) as text)
            if prependHTML is not "" then set current to prependHTML & current
            if appendHTML is not "" then set current to current & appendHTML
            set body of n to current
        end tell
        return "ok"
    end run

    on resolveNote(noteID)
        tell application "Notes"
            try
                set theNote to note id noteID
                set probe to (name of theNote)
                return theNote
            end try
            set matches to (notes whose id is noteID)
            if (count of matches) is 0 then
                error "REMOTE_SHORTCUTS_NOT_FOUND" number -1728
            end if
            return item 1 of matches
        end tell
    end resolveNote
    """

    /// argv: 1 note id. Notes moves deletions to "Recently Deleted".
    static let deleteNote = """
    \(prelude)
    on run argv
        set noteID to item 1 of argv
        tell application "Notes"
            delete (my resolveNote(noteID))
        end tell
        return "ok"
    end run

    on resolveNote(noteID)
        tell application "Notes"
            try
                set theNote to note id noteID
                set probe to (name of theNote)
                return theNote
            end try
            set matches to (notes whose id is noteID)
            if (count of matches) is 0 then
                error "REMOTE_SHORTCUTS_NOT_FOUND" number -1728
            end if
            return item 1 of matches
        end tell
    end resolveNote
    """
}
