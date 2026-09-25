---
tool: socket_list
description: List dart:io socket statistics (TCP/UDP) — addresses, ports, byte counts, open/closed state.
when_to_use: When investigating non-HTTP network behavior — WebSocket frames, gRPC, custom TCP, UDP.
---

## DO NOT USE THIS TOOL WHEN

- You're debugging HTTP requests — use `network_list`. HTTP sockets DO appear here but without request/response context.
- You expect payload data — sockets don't capture payloads, only byte counts and timing.
- The platform doesn't support socket profiling (some embedders strip it): live reads fail with `capability_disabled`.
- You're looking at "socket connections" in a high-level sense (e.g., Socket.IO frames) — this is the raw `dart:io` level, not framing.
- You only need open-vs-closed counts — that's in the `summary` line; no need to scan the full array.

## Use this when

- A WebSocket connection looks off — see if bytes flow.
- Suspected leak — sockets with no `endTimeUs` (still open).
- gRPC or custom-protocol traffic that doesn't show in HTTP tools.

## How it works

The session resolves like the other read tools: `sessionId`, else `appNameContains` (attached sessions only), else the `session_open` view, else the sole attached session, else a default pick among several attached.

Live mode (the scope is a session attached to this server, reached through `sessionId`, `appNameContains`, or the default; a `session_open` view is always history): `ext.dart.io.getSocketProfile` on each HTTP-profiling isolate (or only `isolateId`), merged. If some isolates fail, the result is `partial: true` with a warning. If every isolate fails, it falls back to the DB copy with `source: "live-db-fallback"`, `degraded: true`, and the reason as the first warning.

History mode (a `session_open` view, or an explicit `sessionId` not attached here): SQL on `socket_events`, filtered by `isolateId` when given. A live session opened with `session_open` is read in history mode.

Both sorted newest-first by `startTimeUs`. Null timing fields (`endTimeUs`, `lastReadTimeUs`, `lastWriteTimeUs`; in history also `startTimeUs`, `isolateId`) are omitted per-row. `open` is true when there is no `endTimeUs`.

## Args

- `sessionId` (int, optional): session to read. Omit to auto-resolve.
- `appNameContains` (string, optional): pick an attached session by app-name substring instead of `sessionId`; must match exactly one.
- `isolateId` (string, optional): restrict to one isolate (id from `network_status`). Omit to merge all isolates.
- `limit` (int, default 50, max 200): values of 0 or below fall back to 50; values above 200 are clamped to 200.

## Returns

```json
{
  "source": "live",
  "scope": {"sessionId": 14, "appName": "sanga_mobile", "isLive": true},
  "sessionId": 14,
  "summary": "3 socket(s) (1 open) in session 14 (live, newest-first).",
  "count": 3,
  "totalCaptured": 3,
  "sockets": [
    {"id":"...", "socketType":"tcp", "address":"...", "port":443, "isolateId":"isolates/1234",
     "startTimeUs":1700..., "readBytes":12345, "writeBytes":456, "open":true}
  ],
  "nextSteps": [
    "socket_get id:\"...\" — detail on the newest socket",
    "network_list — see HTTP traffic alongside (HTTP uses TCP sockets too)"
  ]
}
```

`totalCaptured` (live only) counts every socket read before `limit`; when it exceeds `count` the summary says how many more were capped. History replies have `source: "history"`, a summary like `3 socket(s) in session 13 (1 open).`, and no `totalCaptured`.

`warnings` appears when the result is empty (live: drive the app; history: the session may not have used sockets, or socket profiling was off at attach), when some isolates did not respond, and on DB fallback. nextSteps: `socket_get` on the newest socket and `network_list` when there are rows; when empty, drive the app (live) or `session_close` (history).

Errors: socket profiling off for a live session returns `capability_disabled` (nextSteps: `network_status`, re-attach); a DB failure in history mode returns `internal`. Scope failures (nothing attached or opened, no `appNameContains` match, several matches) return an error with `nextSteps` but no `errorKind`.

## Pairs well with

- `socket_get` — drill into one.
- `network_list` — same connections viewed at HTTP level.
- `socket_clear` — reset before triggering a specific action.

## Example

```
> socket_list limit:10
< {summary:"3 socket(s) (1 open) in session 14 (live, newest-first).", ...}
> socket_get id:"sock-7"
```
