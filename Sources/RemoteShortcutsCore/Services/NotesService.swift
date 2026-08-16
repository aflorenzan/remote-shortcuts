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
        if message.contains("REMOTE_SHORTCUTS_NOT_FOUND") {
            return .notFound("No matching note or folder")
        }
        if lowered.contains("-1728") {
            return .notFound("Apple Notes could not find the requested item")
        }
        return .upstreamFailure("Apple Notes returned an error (exit \(exitCode)): \(message.isEmpty ? "no detail" : message)")
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

/// Every script here is a constant. Values reach them through `argv` only.
private enum Scripts {
    /// Shared prelude.
    ///
    /// It contains handlers only. A script with an explicit `on run` handler
    /// may not also carry loose top-level statements, so the separators are
    /// declared as properties (evaluated at compile time) rather than with
    /// `set` at the top level.
    ///
    /// `isoDate` exists because AppleScript renders dates in the user's locale
    /// ("Friday, 15 August 2026 at 09:00"), which no date parser should have to
    /// guess at. Emitting ISO-8601 by hand keeps the output locale-independent.
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
        tell application "Notes" to return (count of folders) as text
    end run
    """

    static let listFolders = """
    \(prelude)
    on run argv
        set output to ""
        tell application "Notes"
            repeat with f in folders
                set accountName to ""
                try
                    set accountName to (name of container of f)
                end try
                set output to output & ((id of f) as text) & fieldSep & ((name of f) as text) & fieldSep & ¬
                    ((count of notes of f) as text) & fieldSep & accountName & recordSep
            end repeat
        end tell
        return output
    end run
    """

    /// argv: 1 folder filter (may be ""), 2 search text (may be ""),
    ///       3 limit, 4 "1" to include the HTML body.
    ///
    /// Properties are fetched in bulk (`id of candidates` rather than `id of n`
    /// inside a loop). Each property access across the `tell` boundary is a
    /// separate Apple Event, so the per-note form costs four round trips per
    /// note — minutes for a large folder. This form costs four per folder.
    static let listNotes = """
    \(prelude)
    on run argv
        set folderFilter to item 1 of argv
        set searchText to item 2 of argv
        set maxCount to (item 3 of argv) as integer
        set wantBody to ((item 4 of argv) is "1")

        set output to ""
        set emitted to 0

        tell application "Notes"
            if folderFilter is not "" then
                set targetFolders to (folders whose name is folderFilter)
                if (count of targetFolders) is 0 then error "REMOTE_SHORTCUTS_NOT_FOUND" number -1728
            else
                set targetFolders to folders
            end if

            repeat with f in targetFolders
                if emitted < maxCount then
                    set folderName to ((name of f) as text)
                    if searchText is not "" then
                        set candidates to (notes of f whose name contains searchText)
                    else
                        set candidates to notes of f
                    end if

                    set noteCount to (count of candidates)
                    if noteCount > 0 then
                        set idList to (id of candidates)
                        set nameList to (name of candidates)
                        set createdList to (creation date of candidates)
                        set modifiedList to (modification date of candidates)
                        if wantBody then
                            set bodyList to (body of candidates)
                        else
                            set bodyList to {}
                        end if

                        repeat with i from 1 to noteCount
                            if emitted < maxCount then
                                set bodyField to ""
                                if wantBody then set bodyField to ((item i of bodyList) as text)
                                set output to output & ((item i of idList) as text) & fieldSep & ¬
                                    ((item i of nameList) as text) & fieldSep & folderName & fieldSep & ¬
                                    my isoDate(item i of createdList) & fieldSep & ¬
                                    my isoDate(item i of modifiedList) & fieldSep & bodyField & recordSep
                                set emitted to emitted + 1
                            end if
                        end repeat
                    end if
                end if
            end repeat
        end tell
        return output
    end run
    """

    /// argv: 1 note id.
    static let getNote = """
    \(prelude)
    on run argv
        set noteID to item 1 of argv
        tell application "Notes"
            set matches to (notes whose id is noteID)
            if (count of matches) is 0 then error "REMOTE_SHORTCUTS_NOT_FOUND" number -1728
            set n to item 1 of matches
            set folderName to ""
            try
                set folderName to (name of container of n)
            end try
            return ((id of n) as text) & fieldSep & ((name of n) as text) & fieldSep & folderName & fieldSep & ¬
                my isoDate(creation date of n) & fieldSep & my isoDate(modification date of n) & fieldSep & ¬
                ((body of n) as text) & fieldSep & ((plaintext of n) as text) & recordSep
        end tell
    end run
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
                set targetFolders to (folders whose name is folderName)
                if (count of targetFolders) is 0 then error "REMOTE_SHORTCUTS_NOT_FOUND" number -1728
                set newNote to make new note at (item 1 of targetFolders) with properties {body:noteBody}
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
            set matches to (notes whose id is noteID)
            if (count of matches) is 0 then error "REMOTE_SHORTCUTS_NOT_FOUND" number -1728
            set body of (item 1 of matches) to newBody
        end tell
        return "ok"
    end run
    """

    /// argv: 1 note id, 2 HTML to append (may be ""), 3 HTML to prepend (may be "").
    static let appendBody = """
    \(prelude)
    on run argv
        set noteID to item 1 of argv
        set appendHTML to item 2 of argv
        set prependHTML to item 3 of argv
        tell application "Notes"
            set matches to (notes whose id is noteID)
            if (count of matches) is 0 then error "REMOTE_SHORTCUTS_NOT_FOUND" number -1728
            set n to item 1 of matches
            set current to ((body of n) as text)
            if prependHTML is not "" then set current to prependHTML & current
            if appendHTML is not "" then set current to current & appendHTML
            set body of n to current
        end tell
        return "ok"
    end run
    """

    /// argv: 1 note id. Notes moves deletions to "Recently Deleted".
    static let deleteNote = """
    \(prelude)
    on run argv
        set noteID to item 1 of argv
        tell application "Notes"
            set matches to (notes whose id is noteID)
            if (count of matches) is 0 then error "REMOTE_SHORTCUTS_NOT_FOUND" number -1728
            delete (item 1 of matches)
        end tell
        return "ok"
    end run
    """
}
