---
tool: logs_tail
description: Recent VM service log/stdout/stderr records from the in-memory ring buffer (live) or persistent DB (history), with cursor + filters.
when_to_use: When you suspect a network/app issue had a corresponding log message, OR when you want the app's print/log output directly.
---

## DO NOT USE THIS TOOL WHEN

- You want a push stream — this is a snapshot. Re-call with `since:<prior nextCursor>` to poll incrementally.
- You're looking specifically for warnings/errors AND the `alerts` capability is on — `alerts_drain` runs the same severity logic and tells you what was flagged.
- The live ring buffer rotated past what you need (capacity 500). Switch to history via `session_open` — the DB has all log records.
- You want logs from a different session — `session_open` first, then call this. There's no `sessionId` arg here intentionally; the read pointer drives it.
- The user just attached — log records start landing as soon as the app prints; if buffer is empty, drive the app first.

## Use this when

- A network failure happened and you want to see what the app logged at that moment.
- The user mentioned a specific log string — combine with `loggerContains` or `network_search` for body matches too.
- Debugging non-network issues — state machine warnings, layout overflows, etc.
- Polling incrementally — call once, keep `nextCursor`, call again with `since:<that cursor>`.

## How it works

Live: reads from a bounded `LogBuffer` (default capacity 500, configurable via `FLUTTER_NETWORK_MCP_LOG_BUFFER`).
History: SQL on `log_records` for the viewed session.

Per-record `message` is capped at 2 KB; longer messages return `{truncated:true, totalLength}`. Severe records (`level ≥ 1200`) get counted into a top-level `severeCount` field when > 0.

## Args

- `since` (int, optional) — local cursor from a prior `nextCursor`.
- `levelMin` (int, optional) — package:logging severity threshold (only affects Logging-source records).
- `loggerContains` (string, optional) — case-insensitive substring on logger name.
- `source` (string, optional) — `"logging"` | `"stdout"` | `"stderr"`.
- `limit` (int, default 100, hard cap 500).

## Returns

```json
{
  "source": "live",
  "sessionId": 14,
  "summary": "12 record(s) from live session 14, 2 severe (level ≥ 1200); filtered by level≥900.",
  "count": 12,
  "bufferSize": 412,
  "streamActive": true,
  "severeCount": 2,
  "nextCursor": 412,
  "nextSteps": [
    "alerts_drain — see what the detector flagged for these severe records",
    "logs_tail since:412 — page incrementally on next call"
  ],
  "entries": [
    {"id":412, "source":"logging", "timestampMs":..., "level":1200,
     "loggerName":"AuthService", "message":"NullPointerException in handler"}
  ]
}
```

`warnings: []` surfaces: stream not subscribed, buffer near rotation, no matches under current filters.
Per-entry null fields (level, loggerName, error, stackTrace) are omitted.

## Pairs well with

- `alerts_drain` — typically more useful than raw log tailing when alerts are on.
- `network_search` — when the same string appears in HTTP bodies too.
- `session_open` — read logs from a past session.

## Example

```
> logs_tail levelMin:1000 limit:20
< {summary:"3 record(s) from live session 14, 1 severe (level ≥ 1200); filtered by level≥1000.",
   entries:[{level:1200, message:"NullPointerException..."}],
   nextSteps:["alerts_drain — see what the detector flagged for these severe records",
              "logs_tail since:412 — page incrementally on next call"]}
```
