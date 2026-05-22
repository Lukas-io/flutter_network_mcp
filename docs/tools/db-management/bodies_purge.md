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
- You expect to re-fetch bodies later — purged bodies aren't recoverable. The `bodies_fetched` flag is reset, but historical bodies are gone.

## Use this when

- A session has dozens of huge JSON responses you no longer need.
- Mass cleanup of old sessions where metadata is still interesting but bodies aren't.

## How it works

Dry-run (default): counts rows and bytes via a single SQL aggregate so the agent can echo the impact before committing. Confirmed: `DELETE FROM http_bodies WHERE <filter>` + resets `http_requests.bodies_fetched`. **Disk space is NOT reclaimed** — run `db_vacuum` afterwards.

## Args

- `sessionId` (int, optional).
- `olderThanMs` (int, optional) — millis-since-epoch. Bodies of requests with `start_us` older than this.
- `confirm` (bool, default false) — required to actually purge.

At least one of `sessionId` / `olderThanMs` is required.

## Returns

Dry-run:
```json
{
  "summary": "DRY-RUN — would purge 126 body BLOB(s) totaling 38.20 MB. Cannot be undone.",
  "dryRun": true,
  "sessionId": 14,
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
  "warnings": ["Disk space is NOT reclaimed yet — run db_vacuum to compact the file."],
  "nextSteps": ["db_vacuum — reclaim disk space", "db_stats — confirm the new size"]
}
```

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
