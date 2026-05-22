---
tool: socket_list
description: List dart:io socket statistics (TCP/UDP) — addresses, ports, byte counts.
when_to_use: When investigating non-HTTP network behavior — websockets at the framing level, gRPC, custom TCP, UDP.
---

## DO NOT USE THIS TOOL WHEN

- You're debugging HTTP requests — use `network_list`. HTTP sockets DO appear here but without request/response context.
- You expect payload data — sockets don't capture payloads, only byte counts and timing.
- The platform doesn't support socket profiling (some embedders strip it). Check `network_status.socketProfilingEnabled`.
- You're looking at "socket connections" in a high-level sense — this is the raw dart:io level, not e.g. Socket.IO frames.

## Use this when

- A WebSocket connection looks off — see if bytes are flowing in/out.
- Suspected leak — check for sockets with no `endTimeUs` (still open).
- gRPC or custom-protocol traffic that doesn't show up in HTTP tools.

## How it works

Live mode: `ext.dart.io.getSocketProfile`. History mode: SQL on `socket_events`.

## Args

- `limit` (int, default 50, hard cap 200).

## Returns

```json
{
  "source": "live",
  "sessionId": 14,
  "count": 3,
  "sockets": [
    {"id":"...", "socketType":"tcp", "address":"...", "port":443,
     "startTimeUs":..., "endTimeUs":null, "readBytes":12345, "writeBytes":456,
     "open": true}
  ]
}
```

## Pairs well with

- `socket_get` — drill into one socket.
- `socket_clear` — reset before triggering an action.

## Example

```
> socket_list limit:10
< [{id:..., open:true, readBytes:0, writeBytes:512}]
```
