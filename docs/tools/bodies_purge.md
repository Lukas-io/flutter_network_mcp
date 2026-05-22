---
tool: bodies_purge
description: Drop captured request/response BLOBs while keeping the http_requests summary metadata intact.
when_to_use: When the DB is getting big because of body BLOBs but you want to keep the metadata (timing, status codes, URLs).
---

## DO NOT USE THIS TOOL WHEN

- You want to delete sessions entirely — use `session_delete` instead.
- You only have one session worth of data — purging may be premature. Check `db_stats` first.
- You haven't passed `sessionId` OR `olderThanMs` — the tool refuses to purge every body in the DB. You must scope.
- You want a dry-run preview — that's the default (omit `confirm:true`). The dry-run currently just echoes args; it does NOT yet return "would purge N rows" (TODO).
- You expect to also re-fetch bodies later — purged bodies aren't recoverable. The `bodies_fetched` flag gets reset so live mode might re-backfill, but historical bodies are gone.

## Use this when

- A session has dozens of huge JSON responses you no longer need.
- Mass cleanup of old sessions where metadata is still interesting (e.g., to see which endpoints were called) but bodies aren't.

## How it works

`DELETE FROM http_bodies WHERE <filter>`. Sets `http_requests.bodies_fetched = 0` for the affected sessions so the live writer would re-backfill if the session is somehow still attachable (it usually isn't for old sessions).

## Args

- `sessionId` (int, optional).
- `olderThanMs` (int, optional) — millis-since-epoch. Bodies of requests with `start_us` older than this.
- `confirm` (bool, default false) — required to actually purge.

## Returns

Dry-run:
```json
{"dryRun":true, "sessionId":14, "olderThanMs":null,
 "message":"Pass confirm:true to actually purge."}
```
Confirmed:
```json
{"purgedBodies":126, "sessionId":14, "olderThanMs":null}
```

## Pairs well with

- `db_stats` — confirm what was reclaimed.
- `db_vacuum` — actually shrink the file on disk after purge.
- `session_delete` — heavier-weight alternative.

## Example

```
> db_stats
< {bodiesMb:"38.20"}
> bodies_purge olderThanMs:1700000000000 confirm:true
< {purgedBodies:1842}
> db_vacuum
> db_stats
< {bodiesMb:"0.50"}
```
