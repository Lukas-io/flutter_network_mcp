---
tool: session_delete
description: Permanently delete a session and ALL its captured data. Dry-run by default; requires confirm:true.
when_to_use: When freeing disk space by removing sessions no longer worth keeping.
---

## DO NOT USE THIS TOOL WHEN

- The session is LIVE: call `network_detach` first. Delete refuses only when the id is this server's sole attached session. It does NOT refuse a session that is one of two or more attached here, or one another server process is still capturing into, so treat any session without `endedMs` in `session_list` as possibly still capturing (a session held only by another process shows `status: "interrupted"`).
- You want to keep metadata but drop bodies — use `bodies_purge` instead.
- You're not sure — call without `confirm:true` first for a dry-run that shows what would be deleted (counts included).
- The user might want it later — consider `session_export id:<n> format:"har"` as a backup first.

## Use this when

- User explicitly asks to remove a session.
- DB size up and `db_stats` shows old sessions with large body sizes.
- Cleaning up after test runs or failed captures.

## How it works

Two-phase by default. First call (no `confirm:true`): dry-run with full counts so the agent can echo "would delete X http, Y logs, Z sockets". Second call (`confirm:true`): actual `DELETE FROM sessions WHERE id = ?`, which cascades via foreign keys to http_requests, http_bodies, socket_events, log_records, alerts, and session_attachments. FTS5 search rows are dropped first by hand since FTS doesn't honor FK cascades. If the deleted session was the one opened with `session_open`, the read pointer reverts to live. **Disk space is NOT reclaimed**: run `db_vacuum` afterwards.

## Args

- `id` (int, required): session id from `session_list`.
- `confirm` (bool, default false): required true to delete.

## Returns

Dry-run:
```json
{
  "summary": "DRY-RUN — would delete session 7 (eats_mobile) and 38 http, 12 log(s), 3 socket(s). Cannot be undone.",
  "dryRun": true,
  "sessionId": 7,
  "appName": "eats_mobile",
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
  "summary": "Deleted session 7 (eats_mobile) — 38 http, 12 log(s), 3 socket(s) removed.",
  "deleted": true,
  "sessionId": 7,
  "appName": "eats_mobile",
  "counts": {"http":38, "sockets":3, "logs":12},
  "warnings": ["Disk space is NOT reclaimed yet — run db_vacuum to compact the file."],
  "nextSteps": [
    "db_vacuum — reclaim disk space after the delete",
    "session_list — confirm the session no longer appears"
  ]
}
```

`appName`, `endedMs`, and `note` are omitted when null. The confirmed reply's counts are measured just before the delete.

Errors: missing `id` returns `bad_argument`; the id of this server's sole live session returns `bad_argument` with `liveSessionId` and nextSteps to `network_detach` first (checked before the dry-run too); an unknown id returns `not_found`.

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
