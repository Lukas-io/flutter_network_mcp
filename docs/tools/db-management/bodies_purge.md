---
tool: bodies_purge
description: Drop captured request/response BLOBs while keeping http_requests summary metadata intact.
when_to_use: When the DB is large because of body BLOBs but you want to keep the trace.
---

## DO NOT USE THIS TOOL WHEN

- You want to delete sessions entirely — use `session_delete`.
- You only have one session worth of data — purging may be premature. Check `db_stats` first.
- You haven't passed `sessionId` OR `olderThanMs` — the tool refuses to purge every body in the DB.
- You expect a dry-run when you pass no `confirm:true` — actually you GET a dry-run, with a count of rows + bytes that WOULD be purged. Read it before re-calling with confirm.
- You expect to re-fetch bodies later: purged bodies aren't recoverable once the app no longer holds them. The purged requests go back to `bodies_fetched=0`, so for a session that is still capturing (here or in another server process), the capture writer re-fetches any body still in the app's live HTTP profile (the purge is partly undone; the reply warns). Detach first if you want a live session's bodies gone.

## Use this when

- A session has dozens of huge JSON responses you no longer need.
- Mass cleanup of old sessions where metadata is still interesting but bodies aren't.

## How it works

Dry-run (default): counts rows and bytes via a single SQL aggregate so the agent can echo the impact before committing. Confirmed, in one transaction: `DELETE FROM http_bodies WHERE <filter>`, then for exactly the purged requests `bodies_fetched` goes back to 0 and their body text leaves the full-text search index (`http_search`). Their URLs stay searchable, and other requests are untouched. Decrypted body text this process held in memory for search (body decryption on) is dropped for every purged session and rebuilt from what is left on the next search. **Disk space is NOT reclaimed**: run `db_vacuum` afterwards.

Filters combine with AND. `olderThanMs` matches a body when its own request (same session, same request id) started before the cutoff.

Runs without the per-tool deadline, so a large purge does not time out.

## Args

- `sessionId` (int, optional): restrict to one session.
- `olderThanMs` (int, optional): millis-since-epoch. Bodies of requests that started before this, matched within each session.
- `confirm` (bool, default false): required to actually purge.

At least one of `sessionId` / `olderThanMs` is required.

## Returns

Dry-run:
```json
{
  "summary": "DRY-RUN — would purge 126 body BLOB(s) totaling 38.20 MB. Cannot be undone.",
  "dryRun": true,
  "sessionId": 14,
  "olderThanMs": null,
  "wouldPurgeRows": 126,
  "wouldPurgeBytes": 40060421,
  "nextSteps": ["bodies_purge sessionId:14 confirm:true — execute"]
}
```

Confirmed:
```json
{
  "summary": "Purged 126 body BLOB(s) (~38.20 MB). Metadata in http_requests is preserved.",
  "purgedBodies": 126,
  "purgedBytes": 40060421,
  "sessionId": 14,
  "olderThanMs": null,
  "purgedSessions": [14],
  "warnings": ["Disk space is NOT reclaimed yet — run db_vacuum to compact the file."],
  "nextSteps": ["db_vacuum — reclaim disk space", "db_stats — confirm the new size"]
}
```

A dry-run that matches nothing says so and suggests widening the filter. A confirmed purge that matches nothing returns `purgedBodies: 0` with the same warning and nextSteps. `purgedBytes` is the byte total measured just before the delete. `purgedSessions` lists the sessions that lost bodies (omitted when none). When one of them is still capturing (attached here or in another server process), a second warning names it: bodies the app still holds are fetched again.

Errors: neither `sessionId` nor `olderThanMs` returns `bad_argument` (refuses to purge every body in the DB); an unexpected DB failure returns `internal`.

## Pairs well with

- `db_stats` — see impact before AND after.
- `db_vacuum` — actually shrink the file.
- `session_delete` — heavier alternative.

## Example

```
> db_stats
< {bodiesMb:"38.20"}
> bodies_purge sessionId:14
< {dryRun:true, wouldPurgeRows:126, wouldPurgeBytes:40060421}
> bodies_purge sessionId:14 confirm:true
< {purgedBodies:126}
> db_vacuum
> db_stats
< {bodiesMb:"0.50"}
```
