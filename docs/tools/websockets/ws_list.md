---
tool: ws_list
description: The app's WebSocket connections (url, state, close code and reason, message counts and bytes each way), read from dart:io's timeline events with no app changes.
when_to_use: A realtime feature misbehaves (chat, live prices, presence, sync) and you need to know whether the socket connected, stayed open, and what flowed.
---

## DO NOT USE THIS TOOL WHEN

- You need message contents. They are not captured: dart:io's timeline events carry type and size only.
- The app talks through a native WebSocket client (OkHttp, URLSessionWebSocketTask, cupertino_http). Only dart:io WebSockets (`WebSocket.connect`, web_socket_channel's `IOWebSocketChannel`) are seen.
- The app was built with Dart older than 3.13 (Flutter older than 3.47). Its dart:io has no WebSocket events; the reply says so. Use `network_list` for the upgrade request and `socket_list` for byte counters.

## Use this when

- "The chat never connects": look for `state: "failed"` with `httpStatus` and `error`.
- "It disconnects after a while": read `close` (`1006 by server`, `1000 "done" by app`) and `durationMs`.
- "Messages go out but nothing comes back": compare `sent` and `received`.

## How it works

The capture writer reads new `WebSocket.*` events from the VM timeline on a poll where the socket byte counters moved (default every 2s), and `ws_list` / `ws_get` read the newest events before answering, so a flow you just drove is there. The first read after attach takes whatever the VM's timeline buffer still holds, so a connection opened shortly before attach can appear with its url.

dart:io numbers connections per isolate, in the order their connects finish, but its connect event does not carry the number. A new number is matched to a finished, still unmatched connect by its distance from the nearest number already matched. When there is no such anchor and several connects are waiting (several opened at once right after attach), the earliest is taken and the row carries `uriInferred: true`. A connection opened before capture started shows up with `url: null` once it sends or receives.

## Args

- `sessionId` (int, optional): session to read. Omit to auto-resolve.
- `appNameContains` (string, optional): pick an attached session by app-name substring.
- `urlContains` (string, optional): case-insensitive url filter.
- `state` (string, optional): `connecting`, `open`, `closed`, `failed` (the connect itself failed) or `error`.
- `limit` (int, default 50, max 200).

## Returns

```json
{
  "summary": "2 WebSocket connection(s) in session 31 (1 closed, 1 failed), newest first.",
  "count": 2,
  "connections": [
    {"id": 7, "url": "ws://127.0.0.1:8799/nope", "state": "failed", "startedMs": 1790000001200,
     "sent": 0, "received": 0, "bytesSent": 0, "bytesReceived": 0,
     "error": "Connection to 'http://127.0.0.1:8799/nope#' was not upgraded to websocket", "httpStatus": 404},
    {"id": 6, "url": "ws://127.0.0.1:8799", "state": "closed", "startedMs": 1790000000100, "connectMs": 4,
     "durationMs": 402, "sent": 3, "received": 3, "bytesSent": 247, "bytesReceived": 257,
     "close": "1000 \"done\" by app"}
  ],
  "nextSteps": ["ws_get id:7 - message timeline of the newest connection", "network_list - the HTTP upgrade request (status 101) with its headers"]
}
```

`state` is as last seen: a session whose app died keeps its open connections `open`. Errors: a bad `state` is `bad_argument`; scope failures return `no_session` or `bad_argument` with `nextSteps`.

## Pairs well with

- `ws_get`: one connection's timeline.
- `network_list`: the upgrade request and its headers (auth, subprotocol).
- `correlate_at`: logs and requests around a close or error time.
