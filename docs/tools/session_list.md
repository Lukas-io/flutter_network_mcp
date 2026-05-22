---
tool: session_list
description: List capture sessions (live + history), newest-first, with per-session counts.
when_to_use: When the user references a past session ("yesterday's", "the one where X happened") or you want to confirm what's in the DB.
---

## DO NOT USE THIS TOOL WHEN

- You're already attached and the user is asking about live data — use `network_list` directly.
- You want to read a specific session — list once, then `session_open id:<n>`. Don't re-list every turn.
- You're searching for a session by content — list shows metadata only. Use `network_search` if you remember a string from the requests.

## Use this when

- Investigating a past bug — list, find the session by time/app/note, open it.
- Confirming a session was created/ended properly after `network_attach` + `network_detach`.
- Showing the user a summary of recent captures.

## How it works

SQL on the `sessions` table joined with COUNT subqueries against http_requests / socket_events / log_records. Filters: `projectPath` (exact match), `sinceMs` (ms epoch).

## Args

- `projectPath` (string, optional) — filter by the working directory at attach time.
- `sinceMs` (int, optional) — only sessions started at or after this ms epoch.
- `limit` (int, default 20, hard cap 100).

## Returns

```json
{
  "count": 3,
  "liveSessionId": 14,
  "viewedSessionId": null,
  "sessions": [
    {"id":14, "startedMs":..., "endedMs":null, "isLive":true,
     "appName":"...", "projectPath":"/Users/me/proj", "note":null,
     "counts":{"http":38, "sockets":3, "logs":127}}
  ]
}
```

## Pairs well with

- `session_open` — pick an id, switch read pointer.
- `session_note` — annotate a session before listing again so future-you can find it.
- `session_export` — share an old session as HAR.

## Example

```
> session_list limit:5
< [{id:14, isLive:true}, {id:13, note:"auth bug", counts:{http:18}}]
> session_open id:13
```
