---
tool: session_delete
description: Permanently delete a session and ALL its captured data — cannot be undone.
when_to_use: When freeing disk space by removing sessions that are no longer interesting.
---

## DO NOT USE THIS TOOL WHEN

- The session is the LIVE session — call `network_detach` first. Delete refuses to drop the live one.
- You want to keep the metadata but drop the BLOBs — use `bodies_purge` instead. This deletes EVERYTHING.
- You're not sure — call without `confirm:true` first for a dry-run that shows what would be deleted.
- The user might want it later — once deleted, only the disk's prior state could recover it. Consider `session_export` to HAR first as a backup.
- You're cleaning up many sessions — call `session_list` to find what's worth keeping, but don't run delete in a loop without showing the user what's going.

## Use this when

- The user explicitly asks to remove a session.
- DB size is up and `db_stats` shows old sessions with large body sizes you don't need.
- Cleaning up after a test run or a failed capture.

## How it works

Two-phase by default: a `dry-run` summary first, then `confirm:true` to actually delete. The DELETE cascades via foreign keys to `http_requests`, `http_bodies`, `socket_events`, `log_records`, and `alerts`. FTS5 rows are dropped manually since FTS doesn't honor FK cascades. After delete, `db_vacuum` is needed to reclaim disk space.

## Args

- `id` (int, required).
- `confirm` (bool, default false). Must be `true` to actually delete.

## Returns

Dry-run:
```json
{"dryRun":true, "sessionId":14, "appName":"...", "note":"...",
 "message":"Pass confirm:true to actually delete."}
```
Confirmed:
```json
{"deleted":true, "sessionId":14}
```

## Pairs well with

- `session_list` — find ids before deleting.
- `session_export` — back up first.
- `db_vacuum` — reclaim disk space after deleting.
- `bodies_purge` — middle-ground option (keep metadata, drop bodies).

## Example

```
> session_list limit:50
< [...old sessions...]
> session_delete id:7
< {dryRun:true, appName:"old debug", ...}
> session_delete id:7 confirm:true
< {deleted:true}
> db_vacuum
```
