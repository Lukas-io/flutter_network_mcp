---
tool: socket_clear
description: Wipe the LIVE in-VM socket profile on the attached isolate. Does NOT touch the persistent DB.
when_to_use: Before triggering a specific action when you want an isolated socket profile.
---

## DO NOT USE THIS TOOL WHEN

- You think this deletes history — it doesn't. The DB rows stay. Only the in-VM profile clears.
- You want to delete `socket_events` rows: no tool deletes individual rows (`network_query` is read-only). `session_delete` removes the whole session.
- Socket profiling isn't enabled for the session: fails with `capability_disabled`.
- You're viewing history (`session_open` active) without passing `sessionId` / `appNameContains`: the call targets the opened session and fails with `no_session`, even when the opened session is the live one. `session_close` first, or pass the live `sessionId`.
- You're not attached: nothing to clear. The call fails with a "Not attached" error.

## Use this when

- Isolating sockets created by a specific user action.

## How it works

Resolves the target session like `network_clear` (`sessionId`, else `appNameContains`, else the `session_open` view, else the sole attached session, else a default pick among several attached). The target must be attached to this server with socket profiling enabled. Calls `ext.dart.io.clearSocketProfile` on each of the session's profiling isolates (or only `isolateId`). A failed isolate is listed in `failed` and counted in `warnings`; `cleared` is still `true`, so check `clearedIsolates`.

## Args

- `sessionId` (int, optional): attached session to clear. Omit when exactly one is attached.
- `appNameContains` (string, optional): pick the attached session by app-name substring instead of `sessionId`; must match exactly one.
- `isolateId` (string, optional): clear only this isolate. Omit to clear all.

## Returns

```json
{
  "cleared": true,
  "scope": {"sessionId": 14, "appName": "sanga_mobile", "isLive": true},
  "summary": "Live VM socket profile cleared for session 14 (sanga_mobile): 1 isolate(s). Persistent DB is untouched (socket_events rows remain queryable).",
  "liveSessionId": 14,
  "clearedIsolates": ["isolates/1234"],
  "warnings": ["The persistent DB is NOT cleared. Use session_delete for DB-side removal."],
  "nextSteps": ["socket_list — confirm the live profile is empty",
                "Drive the app, then socket_list — fresh isolated socket capture"]
}
```

`failed: [{isolateId, error}]` appears only when an isolate could not be cleared.

Errors: a session that is not attached here returns `no_session` (nextSteps `network_attach` / `session_delete`); socket profiling off returns `capability_disabled` (nextSteps `network_status`, re-attach). Scope failures (nothing attached, no `appNameContains` match, several matches) return an error with `nextSteps` but no `errorKind`.

## Pairs well with

- `socket_list` — verify empty.
- `network_clear` — sibling for HTTP.

## Example

```
> socket_clear
> # trigger the action
> socket_list
```
