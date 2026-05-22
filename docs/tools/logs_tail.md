---
tool: logs_tail
description: Recent log records from Logging, Stdout, and Stderr streams. Filterable. Cursor-based.
when_to_use: When you suspect a network issue had a corresponding log message (most do), or to read the app's print/log output directly.
---

## DO NOT USE THIS TOOL WHEN

- You want a stream — this is a snapshot. Re-call with `since:<prior nextCursor>` to poll incrementally.
- You're looking for warnings/errors specifically and `alerts` capability is on — use `alerts_drain` instead. It runs the same regex but tells you what's important.
- The ring buffer (500 entries, live mode) has rotated past what you need — switch to history mode via `session_open` and re-tail; the DB has all of them.
- You want logs from a different session — pass `sessionId` after `session_open`, or just open and re-tail.

## Use this when

- A network failure happened and you want to see what the app logged at that moment.
- The user mentioned a specific log message string — combine with `loggerContains` or call `network_search` if you want bodies too.
- Debugging an issue that doesn't produce HTTP traffic — pure logic errors, state machine warnings, etc.

## How it works

Live mode: reads from the in-memory ring buffer (capacity 500).

History mode: SQL on `log_records` for the viewed session.

Per-record `message` field is capped at 2 KB; when capped, `truncated:true` + `totalLength` are included.

## Args

- `since` (int) — local cursor id from prior `nextCursor`.
- `levelMin` (int) — package:logging severity (e.g., 900 = WARNING, 1200 = SEVERE). Only filters Logging-source records.
- `loggerContains` (string) — case-insensitive substring on logger name.
- `source` (string) — `"logging"` | `"stdout"` | `"stderr"`.
- `limit` (int, default 100, hard cap 500).

## Returns

```json
{
  "source": "live",
  "sessionId": 14,
  "count": 12,
  "bufferSize": 412,
  "nextCursor": 412,
  "entries": [
    {"id":412, "source":"logging", "timestampMs":..., "level":1000,
     "loggerName":"AuthService", "message":"login failed", "truncated":false}
  ]
}
```

## Pairs well with

- `alerts_drain` — typically more useful than raw log tailing.
- `network_search` — when you want to also find HTTP requests containing the same string.

## Example

```
> logs_tail levelMin:1000 limit:20
< [{level:1200, message:"NullPointerException in handler"}]
```
