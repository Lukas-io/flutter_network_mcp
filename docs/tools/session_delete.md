---
tool: session_delete
description: Permanently delete a session and ALL its captured data. Dry-run by default; requires confirm:true.
when_to_use: When freeing disk space by removing sessions no longer worth keeping.
---

## DO NOT USE THIS TOOL WHEN

- The session is LIVE — call `network_detach` first. Delete refuses to drop the live one.
- You want to keep metadata but drop bodies — use `bodies_purge` instead.
- You're not sure — call without `confirm:true` first for a dry-run that shows what would be deleted (counts included).
- The user might want it later — consider `session_export id:<n> format:"har"` as a backup first.

## Use this when

- User explicitly asks to remove a session.
- DB size up and `db_stats` shows old sessions with large body sizes.
- Cleaning up after test runs or failed captures.

## How it works

Two-phase by default. First call (no `confirm:true`): dry-run with full counts so the agent can echo "would delete X http, Y logs, Z sockets". Second call (`confirm:true`): actual `DELETE FROM sessions WHERE id = ?` — cascades via foreign keys to http_requests, http_bodies, socket_events, log_records, alerts. FTS5 rows dropped manually since FTS doesn't honor FK cascades. **Disk space is NOT reclaimed** — run `db_vacuum` afterwards.

## Args

- `id` (int, required).
- `confirm` (bool, default false).

## Returns

Dry-run:
```json
{
  "summary": "DRY-RUN — would delete session 7 (sanga_mobile) and 38 http, 12 log(s), 3 socket(s). Cannot be undone.",
  "dryRun": true,
  "sessionId": 7,
  "appName": "sanga_mobile",
  "startedMs": ..., "endedMs": ..., "note": "old debug",
  "counts": {"http":38, "sockets":3, "logs":12},
  "nextSteps": [
    "session_export id:7 format:\"har\" outPath:\"...\" — back up before deleting",
    "session_delete id:7 confirm:true — proceed with the delete"
  ]
}
```

Confirmed:
```json
{
  "summary": "Deleted session 7 (sanga_mobile) — 38 http, 12 log(s), 3 socket(s) removed.",
  "deleted": true,
  "sessionId": 7,
  "counts": {"http":38, "sockets":3, "logs":12},
  "warnings": ["Disk space is NOT reclaimed yet — run db_vacuum to compact the file."],
  "nextSteps": [
    "db_vacuum — reclaim disk space after the delete",
    "session_list — confirm the session no longer appears"
  ]
}
```

## Pairs well with

- `session_list` — find ids before deleting.
- `session_export` — back up first.
- `db_vacuum` — reclaim disk space after.
- `bodies_purge` — middle-ground (keep metadata, drop bodies).

## Example

```
> session_list limit:50
> session_delete id:7
< {dryRun:true, summary:"DRY-RUN — would delete..."}
> session_delete id:7 confirm:true
< {deleted:true, summary:"Deleted session 7..."}
> db_vacuum
```
