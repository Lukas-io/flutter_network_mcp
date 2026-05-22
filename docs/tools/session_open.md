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
- You're opening the LIVE session — harmless but redundant; read tools work the same without it (the tool warns).

## Use this when

- After `session_list` shows the id you want.
- The user references a session by id directly.

## How it works

Validates the id exists, sets `Session.instance.viewedSessionId`. All read tools (`network_list/get/body`, `socket_list/get`, `logs_tail`, `network_search`, `network_diff`) respect this pointer.

## Args

- `id` (int, required).

## Returns

```json
{
  "summary": "Viewing session 13 (sanga_mobile, ended) — read tools now query history.",
  "viewedSessionId": 13,
  "appName": "sanga_mobile",
  "startedMs": ...,
  "endedMs": ...,
  "isLive": false,
  "isEnded": true,
  "nextSteps": [
    "network_list — list the http requests in this session",
    "network_search query:\"...\" — full-text search this session",
    "session_close — revert read pointer to live"
  ]
}
```

`warnings: []` appears when you open the live session (no-op compared to default behavior).

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
