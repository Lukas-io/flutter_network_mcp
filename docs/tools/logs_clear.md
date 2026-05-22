---
tool: logs_clear
description: Empty the in-memory log ring buffer. Does NOT affect the app or persistent DB.
when_to_use: Before triggering an action when you want only that action's log output in the live buffer.
---

## DO NOT USE THIS TOOL WHEN

- You think this deletes history — it doesn't. The DB `log_records` rows remain.
- You're viewing history — irrelevant; this only touches the live ring buffer.
- You want to stop capturing logs — there's no pause. Detach + re-attach with `--disable logs`.
- The buffer is already empty — the call still succeeds but `clearedCount` will be 0.

## Use this when

- Isolating one action's log output before triggering it.

## How it works

Counts the buffer's current size, calls `LogBuffer.clear()`, returns the count of records removed. The capture writer continues to fill the buffer as new events arrive.

## Args

None.

## Returns

```json
{
  "cleared": true,
  "summary": "Cleared 412 log record(s) from live ring buffer. Persistent DB log_records untouched.",
  "clearedCount": 412,
  "streamActive": true,
  "warnings": ["The persistent DB is NOT cleared. Use session_delete for DB-side removal."],
  "nextSteps": [
    "logs_tail — confirm the live buffer is empty",
    "Drive the app, then logs_tail — fresh isolated capture"
  ]
}
```

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
