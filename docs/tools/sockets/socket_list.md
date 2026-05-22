---
tool: socket_list
description: List dart:io socket statistics (TCP/UDP) — addresses, ports, byte counts, open/closed state.
when_to_use: When investigating non-HTTP network behavior — WebSocket frames, gRPC, custom TCP, UDP.
---

## DO NOT USE THIS TOOL WHEN

- You're debugging HTTP requests — use `network_list`. HTTP sockets DO appear here but without request/response context.
- You expect payload data — sockets don't capture payloads, only byte counts and timing.
- The platform doesn't support socket profiling (some embedders strip it). Errors out with a clear message.
- You're looking at "socket connections" in a high-level sense (e.g., Socket.IO frames) — this is the raw `dart:io` level, not framing.
- You only need open-vs-closed counts — that's in the `summary` line; no need to scan the full array.

## Use this when

- A WebSocket connection looks off — see if bytes flow.
- Suspected leak — sockets with no `endTimeUs` (still open).
- gRPC or custom-protocol traffic that doesn't show in HTTP tools.

## How it works

Live mode: `ext.dart.io.getSocketProfile`. History mode: SQL on `socket_events`. Sorted newest-first by `startTimeUs`. Null timing fields are omitted per-row.

## Args

- `limit` (int, default 50, hard cap 200).

## Returns

```json
{
  "source": "live",
  "sessionId": 14,
  "summary": "3 socket(s) (1 open) in session 14 (live, newest-first).",
  "count": 3,
  "totalCaptured": 3,
  "sockets": [
    {"id":"...", "socketType":"tcp", "address":"...", "port":443,
     "startTimeUs":1700..., "readBytes":12345, "writeBytes":456, "open":true}
  ],
  "nextSteps": [
    "socket_get id:\"...\" — detail on the newest socket",
    "network_list — see HTTP traffic alongside (HTTP uses TCP sockets too)"
  ]
}
```

`warnings: []` appears when the profile is empty.

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
