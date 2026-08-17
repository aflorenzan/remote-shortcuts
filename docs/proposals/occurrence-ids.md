# Proposal: addressing a single occurrence of a recurring event

**Status:** open — needs a decision before implementing
**Raised by:** runtime verification, August 2026

## The problem

`GET /v1/calendars/events` expands a recurring series into one row per
occurrence, which is right. But every row carries the **same `id`**, because
that is what `EKEvent.eventIdentifier` returns for a series.

A client therefore cannot say *which* occurrence it means. Everything
downstream inherits that:

- `PATCH`/`DELETE` with `span=this_event` always resolve to the master event
  anchored at the series' **original start**, not to the occurrence the client
  was looking at.
- `span=future_events` anchors at the same place, so "from here onwards" is
  really "from the beginning". Measured: a `PATCH` with `future_events`
  changing the time moved the *entire* series a week later (Dec 7 → Dec 14) and
  `COUNT=6` recalculated the tail out to Jan 18.
- If the first occurrence has already been detached or deleted, that master
  still resolves. Deleting it silently removed nothing; patching it *recreated*
  the deleted occurrence.

Those last two were shipped as separate fixes — the API now returns 404 instead
of lying — but they are symptoms. This is the cause.

## Why it is not just a bug fix

Any real fix changes the public contract: either ids stop being opaque and
gain structure, or the write endpoints grow a parameter. Both break clients
written against the current shape, so it is a decision, not a patch.

## Options

### A. Composite ids — `<identifier>/RID=<timestamp>`

Return a per-occurrence id built from the series identifier plus the
occurrence's start.

EventKit already does exactly this: detach an occurrence and it hands back
`…:330D65C2-…/RID=825598800`. Adopting that format means following the
platform rather than inventing a scheme.

- **For:** ids stay a single opaque string, so client code and the `:id` routes
  are unchanged. Matches what EventKit emits, so round-tripping a detached
  occurrence works with no translation.
- **Against:** ids get longer and contain `/`, which needs the router's greedy
  segment handling (already implemented for Notes ids). Clients that stored an
  id from an older version keep the ambiguous behaviour, silently.
- **Migration:** accept both forms. A bare identifier keeps today's meaning —
  the master — and is documented as such.

### B. Explicit `occurrence_date` parameter

Keep ids as they are; add an optional `occurrence_date` to `PATCH` and
`DELETE`, and to the query string of the delete.

- **For:** ids stay short and unchanged. The semantics are visible in the
  request rather than encoded in a string, which is easier to read in an n8n
  node. Fully backwards compatible.
- **Against:** the client has to carry two values that belong together and
  re-pair them, which is exactly the kind of bookkeeping an API should absorb.
  It also does not fix `GET`: rows still arrive indistinguishable, so the
  client must remember which `start` went with which row.

### C. Both

Emit composite ids **and** accept `occurrence_date`. Rejected as written: two
ways to say the same thing, with the question of what happens when they
disagree.

## Recommendation

**Option A**, for one reason above the others: EventKit already produces that
format, so it is the only option where the id we hand out and the id the
platform hands back are the same thing. Option B leaves `GET` unfixed, which is
where the ambiguity actually starts.

Ship it as a minor version with both forms accepted, and document the bare
identifier as "the series, anchored at its original start".

## Meanwhile

`docs/API.md` documents the current limitation under `span`, and the write
endpoints now return `404` rather than silently doing nothing or resurrecting a
deleted occurrence.
