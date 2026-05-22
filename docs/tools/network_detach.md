---
tool: network_detach
description: Close DTD + VM service connections and mark the live capture session ended. Captured data remains queryable via session_list.
when_to_use: When the investigation is over, or before re-attaching to a different app.
---

## DO NOT USE THIS TOOL WHEN

- You want to STOP capturing but keep querying live — there's no such mode. Detach is permanent for that session; the next attach opens a new one.
- You want to clear captured data — detach doesn't delete anything. Use `network_clear` for live profile, or DELETE via `network_query` for history.
- You're not actually attached. `network_status.attached` should be `true`. Otherwise this is a no-op that just emits `wasAttached:false`.
- You want to "pause" — there is no pause. The writer runs every 2s while attached. If volume is a problem, use `ignored_hosts` to filter noise instead.

## Use this when

- The user signals the investigation is over.
- Before re-attaching to a different DTD URI / app.
- Before exporting a HAR for a teammate (so the session has a proper `ended_at`).

## How it works

Stops the capture writer, cancels the log stream subscription, disposes the VM service + DTD connections, sets `sessions.ended_at`, and clears in-process state (lastHttpCursor, viewedSessionId, attached app name).

## Args

None.

## Returns

```json
{"detached": true, "wasAttached": true, "endedSessionId": 14}
```

## Pairs well with

- `session_list` — confirm the session shows up with `endedMs` set.
- `session_export` — write a HAR from the just-ended session.

## Example

```
> network_detach
< {detached:true, endedSessionId:14}
> session_list limit:3
< [{id:14, endedMs:<now>, counts:{http:38, logs:12}}]
```
