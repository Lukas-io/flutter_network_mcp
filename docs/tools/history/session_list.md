---
tool: session_list
description: List capture sessions (newest-first) with per-session counts, summary, and capability-aware nextSteps.
when_to_use: When the user references a past session, or you want to confirm what's in the DB.
---

## DO NOT USE THIS TOOL WHEN

- You're already attached and the user is asking about live data — use `network_list` directly.
- You want to read a specific session — list once, then `session_open id:<n>`. Don't re-list every turn.
- You're searching for a session by content — list shows metadata only. Use `network_search` for body content.

## Use this when

- Investigating a past bug — list, find the session by time/app/note, open it.
- Confirming a session was created/ended properly after `network_attach` + `network_detach`.
- Showing the user a summary of recent captures.
- Cleanup — list to find old sessions worth `session_delete`.

## How it works

SQL on `sessions` joined with COUNT subqueries against http_requests / socket_events / log_records. Newest-first by `startedMs`. Null per-row fields (appName, note, projectPath, endedMs) are omitted.

Each row carries `status`:
- `live`: this server process is attached to the session right now, or another live server process sharing the same DB captures into it. Several processes attached to the same app share one session row, and the row ends only when the last of them detaches. A row captured only by another process also carries `capturedElsewhere: true`.
- `ended`: the session has an end time.
- `interrupted`: no end time and no live server process captures into it (the capturing process was killed, or the row predates clean-end tracking). When a server starts, it ends open rows that no live server process holds and appends `[orphaned]` to their note.

`isLive` is true only for the session this process is attached to when exactly one is attached. With two or more attached, `liveSessionId` is null and every `isLive` is false; use `status` instead.

## Args

- `appNameContains` (string, optional) — case-insensitive substring match on the app's DTD identity. **This is the reliable way to scope to one app.**
- `projectPath` (string, optional) — exact match on the working directory at attach time. **NOT app identity:** multiple apps launched from the same parent dir share it, so it can return the wrong app. Prefer `appNameContains`.
- `sinceMs` (int, optional): only sessions started at or after this ms-since-epoch.
- `limit` (int, default 20, max 100): values of 0 or below fall back to 20; values above 100 are clamped to 100.

When the listed sessions include more distinct app names than distinct project paths, the result carries a warning naming the apps and pointing at `appNameContains` (issue #27).

## Returns

```json
{
  "summary": "3 session(s) — live: 14, viewing: live.",
  "count": 3,
  "liveSessionId": 14,
  "viewedSessionId": null,
  "nextSteps": [
    "session_open id:13 — read its captures",
    "session_export id:<n> format:\"har\" outPath:\"...\" — share a session as HAR"
  ],
  "sessions": [
    {"id":14, "startedMs":..., "isLive":true, "status":"live", "appName":"...",
     "projectPath":"...", "counts":{"http":38, "sockets":3, "logs":127}},
    {"id":12, "startedMs":..., "isLive":false, "status":"live",
     "capturedElsewhere":true, "appName":"...", "counts":{"http":9, "sockets":0, "logs":40}}
  ]
}
```

`warnings` fires when nothing matches (drop filters or `network_attach`), when 50 or more sessions are listed (suggests `db_stats` / `bodies_purge` / `session_delete`), and for the shared-directory case above.

`nextSteps`: with no rows, `network_status` and `network_attach`. Otherwise `session_open` on the newest non-live row (or the first row), a scoped `session_list appNameContains:"<app>"` when more than one app name is listed, `session_export` when the sessions capability is on, and `session_delete` when 50 or more rows are listed.

Errors: an unexpected DB failure returns `errorKind: "internal"` with `network_status` / `db_stats` in `nextSteps`. A DB locked by another process returns `unresponsive_db`.

## Pairs well with

- `session_open` — pick an id, switch read pointer.
- `session_note` — annotate so future-you can find it.
- `session_delete` — prune old sessions.
- `db_stats` — see DB size impact.

## Example

```
> session_list limit:5
< {summary:"3 session(s) — live: 14, viewing: live.",
   sessions:[{id:14, isLive:true}, {id:13, note:"auth bug", counts:{http:18}}]}
> session_open id:13
```
