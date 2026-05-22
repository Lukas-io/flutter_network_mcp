---
tool: session_open
description: Switch the read pointer for query tools (network_list, network_get, logs_tail, etc.) to a historical session.
when_to_use: When you want to query a past session instead of the live one.
---

## DO NOT USE THIS TOOL WHEN

- You're asking about live data — read tools default to live when no session is opened.
- You opened the wrong session — just call again with a new id. It overwrites.
- You want to stop viewing history and go back to live — use `session_close` (or another `session_open` to a different id).
- You expect this to import the historical session's data into the live one — it doesn't. The live capture keeps writing to its own session.

## Use this when

- After `session_list` shows the session you want.
- The user mentions a session by id directly.

## How it works

Validates the id exists, sets `session.viewedSessionId` in-process. Subsequent calls to `network_list`, `network_get`, `network_body`, `socket_list`, `socket_get`, `logs_tail`, `network_search`, and `network_diff` read from the DB for that session instead of the live VM service.

## Args

- `id` (int, required).

## Returns

```json
{"viewedSessionId": 13, "appName": "...", "startedMs": ..., "endedMs": ...,
 "projectPath": "..."}
```

## Pairs well with

- `session_list` — find the id.
- `session_close` — revert.
- All read tools — they all respect `viewedSessionId`.

## Example

```
> session_open id:13
> network_search query:"401" sessionId:13
> session_close
```
