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
- You expect to re-fetch bodies later: purged bodies aren't recoverable once the app no longer holds them. The `bodies_fetched` flag is reset, so for a session this server is still attached to, the capture writer re-fetches any body still in the app's live HTTP profile (the purge is partly undone). Detach first if you want a live session's bodies gone.

## Use this when

- A session has dozens of huge JSON responses you no longer need.
- Mass cleanup of old sessions where metadata is still interesting but bodies aren't.

## How it works

Dry-run (default): counts rows and bytes via a single SQL aggregate so the agent can echo the impact before committing. Confirmed: `DELETE FROM http_bodies WHERE <filter>` and resets `http_requests.bodies_fetched` to 0: for every request in `sessionId` when it is given, otherwise for every request in the DB. **Disk space is NOT reclaimed**: run `db_vacuum` afterwards.

Filters combine with AND. `olderThanMs` matches bodies whose request id (`vm_id`) belongs to any request, in any session, that started before the cutoff. Request ids come from the app's VM and repeat across app runs, so a newer body that shares an id with an old request is purged too, even when `sessionId` is also passed. Only `sessionId` on its own is exact.

The full-text search index (`http_search`) is not touched, so `network_search` can still match text from purged bodies. `session_delete` clears it.

Runs without the per-tool deadline, so a large purge does not time out.

## Args

- `sessionId` (int, optional): restrict to one session.
- `olderThanMs` (int, optional): millis-since-epoch. Bodies of requests that started before this (see the matching caveat above).
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
  "warnings": ["Disk space is NOT reclaimed yet — run db_vacuum to compact the file."],
  "nextSteps": ["db_vacuum — reclaim disk space", "db_stats — confirm the new size"]
}
```

A dry-run that matches nothing says so and suggests widening the filter. A confirmed purge that matches nothing returns `purgedBodies: 0` with the same warning and nextSteps. `purgedBytes` is the byte total measured just before the delete.

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
