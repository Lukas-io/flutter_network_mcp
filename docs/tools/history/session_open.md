---
tool: session_open
description: Switch the read pointer to a historical (or live) session.
when_to_use: When you want read tools to query a past session instead of the live one.
---

## DO NOT USE THIS TOOL WHEN

- You want live data — read tools default to live when no session is opened.
- You opened the wrong one — just call again with a new id. It overwrites.
- You want to stop viewing history — use `session_close` (or another `session_open`).
- You expect this to import history into the live session — it doesn't. Live keeps writing to its own session.
- You're opening the LIVE session: reads then come from the DB (everything persisted so far) instead of the incremental live profile, and live-only tools (`network_clear`, `socket_clear`, `logs_clear`) refuse to run until you `session_close`. The tool warns.

## Use this when

- After `session_list` shows the id you want.
- The user references a session by id directly.

## How it works

Validates the id exists, sets `Session.instance.viewedSessionId`. Read tools that auto-resolve their scope (`network_list/get/body`, `socket_list/get`, `logs_tail`, `network_search`, `network_diff`, and others) use this pointer when you pass no `sessionId` / `appNameContains`, even while live sessions are attached; their replies then carry a warning saying they read history. An explicit `sessionId` or `appNameContains` on a read tool overrides it.

The summary labels the session `live` (this server process is attached), `live, captured by another server process` (another live server process sharing the DB captures into it; the reply also carries `capturedElsewhere: true`), `ended`, or `interrupted` (no end time and no live server process captures into it). Opening does not attach anything.

## Args

- `id` (int, required): session id from `session_list`.

## Returns

```json
{
  "summary": "Viewing session 13 (sanga_mobile, ended) ...",
  "viewedSessionId": 13,
  "appName": "sanga_mobile",
  "startedMs": ...,
  "endedMs": ...,
  "isLive": false,
  "isEnded": true,
  "projectPath": "/Users/me/sanga_mobile",
  "note": "auth bug",
  "nextSteps": [
    "network_list — list the http requests in this session",
    "network_search query:\"...\" — full-text search this session",
    "session_close — revert read pointer to live"
  ]
}
```

`appName`, `endedMs`, `projectPath`, and `note` are omitted when null; `capturedElsewhere` appears only when true. `isLive` is true only when the id is this process's sole attached session. The `network_list` and `network_search` nextSteps appear only when those capabilities are enabled.

`warnings` appears when you open the live session (this process's sole attached session): reads now come from the DB, not the incremental live profile.

Errors: missing `id` returns `bad_argument`; an unknown id returns `not_found` (nextSteps: `session_list`); an unexpected DB failure returns `internal`.

## Pairs well with

- `session_list` — find the id.
- `session_close` — the inverse.
- All read tools — they respect `viewedSessionId`.

## Example

```
> session_open id:13
> network_search query:"401"
> session_close
```
