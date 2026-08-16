# Using remote-shortcuts from n8n

## 1. Create the credential once

In n8n: **Credentials → New → Header Auth**

| Field | Value |
| --- | --- |
| Name | `Authorization` |
| Value | `Bearer YOUR_TOKEN` |

Get the token with `remote-shortcuts token show`. Every HTTP Request node then
selects this credential instead of carrying the token in the node itself, so
it never lands in an exported workflow.

## 2. Reaching the Mac

| n8n runs… | Do this |
| --- | --- |
| On the same Mac | Use `http://127.0.0.1:8787` directly |
| On another machine, same network | Set `host` to the Mac's LAN IP and fill in `allowed_origins` |
| In the cloud (n8n Cloud, a VPS) | Put both on a Tailscale network and use the Mac's Tailscale IP, or run a Cloudflare Tunnel to `127.0.0.1:8787` |

Don't port-forward it to the internet. Anyone with the token can run any
shortcut on the machine.

## 3. Recipes

### Run a shortcut and use its output

**HTTP Request** node:

- Method: `POST`
- URL: `http://127.0.0.1:8787/v1/shortcuts/run`
- Authentication: Generic → Header Auth → your credential
- Send Body: on, JSON:

```json
{
  "name": "Daily Briefing",
  "input": "{{ JSON.stringify($json) }}"
}
```

Have the shortcut end with a **Text** action containing JSON. The response
then carries a parsed `output_json` you can read as
`{{ $json.output_json.temperature }}` in the next node.

### Create a calendar event from a trigger

```json
{
  "title": "={{ $json.subject }}",
  "start": "={{ $json.startsAt }}",
  "end": "={{ $json.endsAt }}",
  "calendar": "Work",
  "location": "={{ $json.room }}",
  "alarms_minutes_before": [15]
}
```

If your upstream data has no timezone (`2026-08-15T09:00:00`), it is read as
local time on the Mac — usually what you want. Send a `Z` suffix or an offset
when you need an exact instant.

### Turn an email into a reminder

`POST /v1/reminders`:

```json
{
  "title": "={{ $json.subject }}",
  "notes": "={{ $json.from }}\n\n{{ $json.snippet }}",
  "list": "Work",
  "due": "={{ $now.plus(1, 'days').toISO() }}",
  "priority": 1
}
```

### Daily digest into a note

`GET /v1/calendars/events` with query parameters:

- `start` → `={{ $now.startOf('day').toISO() }}`
- `end` → `={{ $now.endOf('day').toISO() }}`

then a **Code** node to format, then `POST /v1/notes`:

```json
{
  "title": "={{ 'Agenda ' + $now.toFormat('yyyy-MM-dd') }}",
  "body": "={{ $json.digest }}",
  "format": "text",
  "folder": "Daily"
}
```

### Append to a running log note

Find the note, then `PATCH /v1/notes/{{ $json.id }}`:

```json
{ "append": "={{ '\\n- ' + $now.toFormat('HH:mm') + ' ' + $json.message }}", "format": "text" }
```

### Complete a reminder

`POST /v1/reminders/{{ $json.id }}/complete` — no body.

## 4. Practical notes

**Timeouts.** A shortcut that opens an app or waits on the network can take a
while. Raise the HTTP Request node's timeout above the shortcut's expected
duration, and pass `"timeout": 300` in the body if it needs longer than the
120-second default.

**Rate limit.** 120 requests/minute per source address by default. A loop over
a large list will trip it — batch, add a Wait node, or raise
`rate_limit_per_minute`.

**Error handling.** Every failure is JSON with a stable `error.code`. Switch
on `{{ $json.error.code }}` to distinguish "the note wasn't there"
(`not_found`) from "macOS blocked us" (`permission_denied`) from "the shortcut
itself failed" (`upstream_failure`).

**The Mac has to be awake.** A sleeping Mac does not answer. For a machine
serving scheduled automations, either disable sleep for the display-off state
or schedule the automation for a time the machine is up. `caffeinate -s` while
you test is handy.

**Discovering names.** `GET /v1/calendars`, `GET /v1/reminders/lists`,
`GET /v1/notes/folders` and `GET /v1/shortcuts` return exactly the names the
write endpoints accept — worth calling once when building a workflow rather
than guessing at capitalisation.
