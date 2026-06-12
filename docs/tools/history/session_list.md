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

SQL on `sessions` joined with COUNT subqueries against http_requests / socket_events / log_records. Newest-first. Null per-row fields (note, projectPath, endedMs) are omitted.

## Args

- `appNameContains` (string, optional) — case-insensitive substring match on the app's DTD identity. **This is the reliable way to scope to one app.**
- `projectPath` (string, optional) — exact match on the working directory at attach time. **NOT app identity:** multiple apps launched from the same parent dir share it, so it can return the wrong app. Prefer `appNameContains`.
- `sinceMs` (int, optional) — ms epoch.
- `limit` (int, default 20, hard cap 100).

When several distinct apps share fewer directories, the result carries a warning naming them and pointing at `appNameContains` (issue #27).

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
    {"id":14, "startedMs":..., "isLive":true, "appName":"...",
     "counts":{"http":38, "sockets":3, "logs":127}}
  ]
}
```

`warnings: []` fires when no matches OR when session count ≥ 50 (suggesting cleanup).

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
