---
tool: network_detach
description: Close DTD + VM service connections, end the live capture session. Captured data remains queryable.
when_to_use: When the investigation is over, or before switching to a different app.
---

## DO NOT USE THIS TOOL WHEN

- You want to STOP capturing but keep querying live — there's no such mode. Detach ends the session; the next attach opens a new one.
- You want to delete captured data — detach doesn't delete anything. Use `session_delete` or `network_query` with DELETE.
- You're not attached — it's a no-op (returns `wasAttached:false`). Harmless but pointless.
- You want to "pause" — there's no pause. Detach + reattach if you must, accepting a new session id.
- You're trying to suppress noisy traffic mid-session — use `ignored_hosts` to filter at capture time without detaching.

## Use this when

- Investigation is over.
- Before reattaching to a different DTD URI / app.
- Before exporting HAR (so the session has a proper `ended_at`).

## How it works

Counts captured rows for the session (http / logs / alerts), stops the capture writer, cancels log stream subs, disposes VM + DTD connections, sets `sessions.ended_at`. All state cleared.

## Args

None.

## Returns

```json
{
  "detached": true,
  "summary": "Detached from sanga_mobile. Session 14 ended — captured 38 http, 12 log(s), 3 alert(s). All queryable via session_open id:14.",
  "wasAttached": true,
  "endedSessionId": 14,
  "captured": {"http": 38, "logs": 12, "alerts": 3},
  "nextSteps": [
    "session_open id:14 — view what was captured",
    "session_list — see all sessions including this one",
    "network_attach — reconnect (same or different app)"
  ]
}
```

When not attached: `{detached:true, summary:"No-op: was not attached.", wasAttached:false, nextSteps:[network_status, network_attach, session_list]}`.

## Pairs well with

- `session_list` — confirm the session shows up with `endedMs` set.
- `session_export` — write a HAR from the just-ended session.
- `session_note` — annotate while you remember why this session existed.

## Example

```
> network_detach
< {detached:true, summary:"Detached from sanga_mobile. Session 14 ended — captured 38 http, 12 log(s), 3 alert(s)..."}
> session_note id:14 note:"auth bug repro for #1842"
```
