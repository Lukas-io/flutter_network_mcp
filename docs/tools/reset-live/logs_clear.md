---
tool: logs_clear
description: Empty the in-memory log ring buffer. Does NOT affect the app or persistent DB.
when_to_use: Before triggering an action when you want only that action's log output in the live buffer.
---

## DO NOT USE THIS TOOL WHEN

- You think this deletes history — it doesn't. The DB `log_records` rows remain.
- You're viewing history (`session_open` active) without passing `sessionId` / `appNameContains`: the call targets the opened session and fails with `no_session`, even when the opened session is the live one. `session_close` first, or pass the live `sessionId`.
- You want to stop capturing logs: there's no pause. Log capture can only be turned off for the whole server by starting it with `--disable logs`.
- The buffer is already empty: the call still succeeds but `clearedCount` will be 0.

## Use this when

- Isolating one action's log output before triggering it.

## How it works

Resolves the target session like the read tools (`sessionId`, else `appNameContains`, else the `session_open` view, else the sole attached session, else a default pick among several attached). The target must be attached to this server. Counts that session's buffer, calls `LogBuffer.clear()`, returns the count of records removed. The log stream keeps filling the buffer as new events arrive, and live `logs_tail` reads from it.

## Args

- `sessionId` (int, optional): attached session to clear. Omit when exactly one is attached.
- `appNameContains` (string, optional): pick the attached session by app-name substring instead of `sessionId`; must match exactly one.

## Returns

```json
{
  "cleared": true,
  "scope": {"sessionId": 14, "appName": "eats_mobile", "isLive": true},
  "summary": "Cleared 412 log record(s) from live ring buffer for session 14 (eats_mobile). Persistent DB log_records untouched.",
  "clearedCount": 412,
  "streamActive": true,
  "warnings": ["The persistent DB is NOT cleared. Use session_delete for DB-side removal."],
  "nextSteps": [
    "logs_tail — confirm the live buffer is empty",
    "Drive the app, then logs_tail — fresh isolated capture"
  ]
}
```

With an empty buffer the summary says it "was already empty". `streamActive: false` means the log stream is not running, so the buffer will not refill.

Errors: a session that is not attached here returns `no_session` (nextSteps `network_attach` / `session_delete`). Scope failures (nothing attached, no `appNameContains` match, several matches) return an error with `nextSteps` but no `errorKind`.

## Pairs well with

- `logs_tail` — verify empty after clear.
- `network_clear` / `socket_clear` — siblings for other live state.

## Example

```
> logs_clear
< {clearedCount:412, summary:"Cleared 412 log record(s)..."}
> # trigger one action
> logs_tail limit:50
```
