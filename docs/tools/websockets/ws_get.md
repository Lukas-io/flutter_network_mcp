---
tool: ws_get
description: One WebSocket connection and its event timeline in order (time since start, direction, type, size, close detail).
when_to_use: After ws_list, to see the order and timing of what one connection sent and received.
---

## DO NOT USE THIS TOOL WHEN

- You need message contents; they are not captured.
- You only need totals or the close reason; `ws_list` already has them.

## Use this when

- Checking the handshake-then-subscribe order of a protocol (the app's first `out` message, then the server's reply).
- Seeing whether keepalive pings got pongs before a drop.
- Timing: how long after connecting the first server message arrived.

## Args

- `id` (int, required): connection id from `ws_list`.
- `sessionId` / `appNameContains` (optional): session scope, as in every read tool.
- `direction` (string, optional): `out` (app to server) or `in` (server to app).
- `kind` (string, optional): `text`, `binary`, `ping`, `pong`, `close` or `error`.
- `afterId` (int, optional): pass the previous reply's `nextAfterId` to page on.
- `limit` (int, default 100, max 500).

## Returns

```json
{
  "summary": "8 event(s) of connection 6 (ws://127.0.0.1:8799, closed), oldest first.",
  "connection": {"id": 6, "url": "ws://127.0.0.1:8799", "state": "closed", "sent": 3, "received": 3, "close": "1000 \"done\" by app"},
  "eventFormat": "+seconds since start, direction, type, size or close detail",
  "events": [
    "+0.004s out text 5B",
    "+0.004s out text 239B",
    "+0.004s out binary 3B",
    "+0.005s in text 10B",
    "+0.005s in text 244B",
    "+0.005s in binary 3B",
    "+0.399s out close 1000 done",
    "+0.400s in close 1000 done"
  ]
}
```

`nextAfterId` appears when more events remain. Errors: a missing `id` or a bad `direction` / `kind` is `bad_argument`; an unknown id is `not_found` (nextSteps: `ws_list`).
