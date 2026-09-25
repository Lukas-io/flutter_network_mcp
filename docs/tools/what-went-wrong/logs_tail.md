---
tool: logs_tail
description: Recent VM service log/stdout/stderr records (plus the native device log when enabled) from the in-memory ring buffer (live) or persistent DB (history), newest-first, with cursor + filters.
when_to_use: When you suspect a network/app issue had a corresponding log message, OR when you want the app's print/log output directly.
---

## DO NOT USE THIS TOOL WHEN

- You want a push stream. This is a snapshot. Re-call with `since:<prior nextCursor>` to poll incrementally.
- You're looking specifically for warnings/errors AND the `alerts` capability is on. `alerts_drain` runs the same severity logic and tells you what was flagged.
- The live ring buffer rotated past what you need (default capacity 2000; `droppedSinceLastRead` tells you). Switch to history via `session_open`; the DB has all log records.
- The user just attached. Log records start landing as soon as the app prints; if the buffer is empty, drive the app first. Records from before the attach were never captured.

## Use this when

- A network failure happened and you want to see what the app logged at that moment.
- The user mentioned a specific log string. Use `messageContains` here, or `network_search` for body matches too.
- Debugging non-network issues: state machine warnings, layout overflows, etc.
- Polling incrementally: call once, keep `nextCursor`, call again with `since:<that cursor>`.
- Native SDK output: attach with `nativeLogs:true`, then read `source:"native"`.

## How it works

Live: reads the attached session's bounded ring buffer, newest-first. Capacity is set per attach: `network_attach logBufferSize`, else `auto_attach_config logBufferSize`, else `FLUTTER_NETWORK_MCP_LOG_BUFFER`, else 2000 (max 20000).
History (a `session_open` view, or a `sessionId` that is not currently attached): SQL on `log_records` for that session, newest-first.

Messages are stored whole. The VM sends each `developer.log` / `package:logging` field (message, logger name, error, stack trace) as a 128-character preview; the server refetches the full string before storing it, in both the live buffer and the DB. An `error:` that is not a String (an Exception, a StateError) is stored as its `toString()`. When the VM cannot expand a value (collected, or no answer within 2s), the stored text is the preview followed by `… [cut by the VM at 128 of N chars]`, so the loss is visible.

Each returned `message` is cut at `messageTruncateBytes` characters (default 2048). A cut record carries `truncated:true` and `totalLength` (the full length in characters), and a warning counts the cut records. A cut never splits an emoji or other astral character. `error` and `stackTrace` are returned uncut.

Filters you omit fall back to the sticky defaults from `session_configure` (`levelMin`, `loggerContains`, `messageContains`, `source`). Severe records (`level ≥ 1200`) are counted into `severeCount` when > 0.

## Args

- `sessionId` (int, optional): session to read. Omit to auto-resolve: the session you opened with `session_open`, else the sole attached one, else (several attached) the one for this project or the most recently used, which `scope.pickedBy` names.
- `appNameContains` (string, optional): pick the session by app-name substring instead of `sessionId`.
- `since` (int, optional): cursor from a prior `nextCursor`. Returns only records newer than it.
- `levelMin` (int, optional): min severity on the logging scale (WARNING 900, SEVERE 1200). Records without a level (stdout, stderr, native) count as 0, so any `levelMin` above 0 drops them.
- `loggerContains` (string, optional): case-insensitive substring on the logger name.
- `messageContains` (string or list, optional): substring(s) on the message, OR-matched. Useful when loggers are unnamed.
- `source` (string, optional): `"logging"` | `"stdout"` | `"stderr"` | `"native"` (only when the attach requested `nativeLogs`). Omit for all.
- `isolateId` (string, optional): restrict to one isolate (id from `network_status`). Omit to merge all isolates.
- `limit` (int, default 100, hard cap 500).
- `messageTruncateBytes` (int, default 2048): cut each message at this many characters. Clamped to 64 to 65536.

## Returns

```json
{
  "source": "live",
  "scope": {"sessionId": 14, "appName": "eats_mobile", "isLive": true},
  "sessionId": 14,
  "summary": "12 record(s) from live session 14 (eats_mobile), 2 severe (level ≥ 1200); filtered by level≥900.",
  "count": 12,
  "bufferSize": 412,
  "bufferCapacity": 2000,
  "streamActive": true,
  "severeCount": 2,
  "nextCursor": 412,
  "nextSteps": [
    "alerts_drain ... 2 severe record(s) in this page raised alerts",
    "logs_tail since:412 ... page incrementally on next call"
  ],
  "entries": [
    {"id":412, "source":"logging", "timestampMs":..., "level":1200,
     "loggerName":"AuthService", "message":"Token refresh failed for user 8812",
     "error":"Bad state: refresh token expired", "stackTrace":"#0 ..."},
    {"id":409, "source":"logging", "timestampMs":..., "level":800,
     "message":"START aaaa...", "truncated":true, "totalLength":6120}
  ]
}
```

History replies have `"source":"history"` and no `bufferSize` / `bufferCapacity` / `streamActive`.
Per-entry null fields (isolateId, level, loggerName, error, stackTrace) are omitted.
Live only: `droppedSinceLastRead` (records that rotated out of the buffer since the previous read, with a warning).
`warnings` surfaces: messages cut at `messageTruncateBytes`, records rotated out since the last read, the app running before the attach (records from then were never captured), log stream not subscribed, buffer near capacity (80%+), no matches under the current filters.

Errors: a failed history query returns `errorKind: internal`. Scope errors (nothing attached and no session open, or an `appNameContains` that matches no attached session or several) come from the shared scope resolver with `nextSteps` and no `errorKind`.

## Pairs well with

- `alerts_drain`: typically more useful than raw log tailing when alerts are on.
- `network_search`: when the same string appears in HTTP bodies too.
- `correlate_at`: which request fired closest to a log line.
- `session_open`: read logs from a past session.
- `session_configure`: set `levelMin` / `messageContains` once for a series of reads.

## Example

```
> logs_tail levelMin:1000 limit:20
< {summary:"3 record(s) from live session 14, 1 severe (level ≥ 1200); filtered by level≥1000.",
   entries:[{level:1200, message:"Token refresh failed...", error:"Bad state: refresh token expired"}],
   nextSteps:["alerts_drain ...", "logs_tail since:412 ..."]}
```

A long message:
```
> logs_tail messageContains:"START" messageTruncateBytes:200
< {entries:[{message:"START aaaa...", truncated:true, totalLength:608}],
   warnings:["1 message(s) cut at the byte limit (truncated:true, totalLength given) ..."]}
> logs_tail messageContains:"START" messageTruncateBytes:1000
< {entries:[{message:"START aaaa...aaaEND"}]}
```
