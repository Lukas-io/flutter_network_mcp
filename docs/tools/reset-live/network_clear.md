---
tool: network_clear
description: Wipe the LIVE in-VM HTTP profile on the attached isolate. Does NOT touch the persistent DB.
when_to_use: To isolate one user action's traffic, OR to reset the cursor without managing it manually.
---

## DO NOT USE THIS TOOL WHEN

- You think this deletes session history — it doesn't. The DB rows stay. Only the in-VM profile clears. Use `session_delete` / `bodies_purge` for DB cleanup.
- You're viewing history (`session_open` active) without passing `sessionId` / `appNameContains`: the call targets the opened session and fails with `no_session` ("Cannot clear a historical session"), even when the opened session is the live one. `session_close` first, or pass the live `sessionId`.
- You're not attached: nothing to clear. The call fails with a "Not attached" error.
- You want to delete sockets too — use `socket_clear`. They're separate VM profiles.

## Use this when

- About to trigger a specific user action and want isolated network output ("clear, then tap login, then `network_list`").
- The cursor has drifted and you want a fresh start without managing offsets.

## How it works

Resolves the target session like the read tools (`sessionId`, else `appNameContains`, else the `session_open` view, else the sole attached session, else a default pick among several attached, reported as `scope.pickedBy` with the alternatives in `scope.others`). The target must be attached to this server. Calls `ext.dart.io.clearHttpProfile` on each of that session's HTTP-profiling isolates (or only `isolateId`) and, when at least one was cleared, resets that session's `lastHttpCursor` to null. The DB session row + all captured `http_requests` / `http_bodies` / `alerts` etc. stay intact.

A failed isolate does not fail the call while another one was cleared: it is listed in `failed` with its error and counted in `warnings`, the reply carries `partial:true`, and the summary says how many of the isolates were cleared. When no isolate was cleared the call fails instead (see Errors), and the cursor is left as it was.

## Args

- `sessionId` (int, optional): attached session to clear. Omit when exactly one is attached.
- `appNameContains` (string, optional): pick the attached session by app-name substring instead of `sessionId`; must match exactly one.
- `isolateId` (string, optional): clear only this isolate. Omit to clear all of the session's HTTP-profiling isolates.

## Returns

```json
{
  "cleared": true,
  "scope": {"sessionId": 14, "appName": "eats_mobile", "isLive": true},
  "summary": "Live VM HTTP profile cleared for session 14 (eats_mobile): 1 of 1 isolate(s). Persistent DB is untouched (captured rows remain queryable).",
  "liveSessionId": 14,
  "clearedIsolates": ["isolates/1234"],
  "warnings": ["The persistent DB is NOT cleared. Use session_delete or bodies_purge to remove historical rows."],
  "nextSteps": [
    "network_list — confirm the live profile is empty",
    "Drive the app, then network_list — fresh isolated capture"
  ]
}
```

`failed: [{isolateId, error}]` and `partial:true` appear only when an isolate could not be cleared.

Errors: a session that is not attached here (opened via `session_open`, or an explicit historical `sessionId`) returns `no_session` with nextSteps `network_attach` / `bodies_purge` / `session_delete`; a session with no known HTTP-profiling isolates returns `no_session`. When every isolate failed to clear, the call returns `cleared:false` with `failed` and `errorKind` `not_found` (the VM does not know that isolate id, for example a wrong `isolateId`) or `unresponsive_vm` (anything else); nextSteps say to retry with the app in the foreground or re-attach. Scope failures return `no_session` (nothing attached or opened, or no attached session matches `appNameContains`) or `bad_argument` (several attached sessions match), with `nextSteps`.

## Pairs well with

- `network_list` — verify empty after clear.
- `bodies_purge` / `session_delete` — when you actually mean "delete data".
- `socket_clear` / `logs_clear` — the sibling clears for other live state.

## Example

```
> network_clear
< {cleared:true, summary:"Live VM HTTP profile cleared..."}
> # tap "Refresh" in the app
> network_list
< {count:1, requests:[<just the refresh call>]}
```
