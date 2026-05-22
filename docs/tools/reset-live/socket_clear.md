---
tool: socket_clear
description: Wipe the LIVE in-VM socket profile on the attached isolate. Does NOT touch the persistent DB.
when_to_use: Before triggering a specific action when you want an isolated socket profile.
---

## DO NOT USE THIS TOOL WHEN

- You think this deletes history — it doesn't. The DB rows stay. Only the in-VM profile clears.
- You want to delete `socket_events` rows — use `network_query` with DELETE, or `session_delete` for the whole session.
- Socket profiling isn't enabled — errors with that exact message.
- You're not attached — nothing to clear.

## Use this when

- Isolating sockets created by a specific user action.

## Args

None.

## Returns

```json
{
  "cleared": true,
  "summary": "Live VM socket profile cleared. Persistent DB session 14 is untouched (socket_events rows remain queryable).",
  "liveSessionId": 14,
  "warnings": ["The persistent DB is NOT cleared. Use session_delete for DB-side removal."],
  "nextSteps": ["socket_list — confirm the live profile is empty",
                "Drive the app, then socket_list — fresh isolated socket capture"]
}
```

## Pairs well with

- `socket_list` — verify empty.
- `network_clear` — sibling for HTTP.

## Example

```
> socket_clear
> # trigger the action
> socket_list
```
