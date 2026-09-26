---
tool: network_detach
description: Stop capturing from one attached session (or all of them), close its VM service connection, and end the DB session. Captured data remains queryable.
when_to_use: When the investigation is over, or to free a slot before attaching another app.
---

## DO NOT USE THIS TOOL WHEN

- You want to STOP capturing but keep querying live. There's no such mode. Detach stops capture; later reads of that session are history reads.
- You want to delete captured data. Detach doesn't delete anything. Use `session_delete`.
- You're not attached. It's a no-op (returns `wasAttached:false`). Harmless but pointless.
- You want to "pause". There's no pause. `keep:true` frees the slot without ending the session, but nothing is captured until you attach again.
- You're trying to suppress noisy traffic mid-session. Use `ignored_hosts` to filter at capture time without detaching.
- You only want to attach a second app. Several apps can be attached at once; detach only when the session cap is reached.

## Use this when

- Investigation is over.
- The session cap (`GLINT_NETWORK_MAX_ATTACH`) is reached and you need a slot for another app.
- Before exporting HAR (so the session has a proper `ended_at`).

## How it works

Picks the target: `all:true` takes every attached session; else `sessionId`; else `appNameContains`; else the only attached session. With 2+ attached and no selector, it errors instead of guessing.

For each target: counts the captured rows (http / logs / alerts), flushes bodies still pending from the VM (bounded, about 3s), stops the capture writer, the log stream and the native log, and disconnects the VM service. Then it ends the session row (`sessions.ended_at`), unless `keep:true`.

Several server processes (for example two IDE windows) can capture into one shared session row. Detach only removes this process from it; the row ends when the last process leaves. When another live process still captures into it, the row stays open, the summary says "stays open: another server process is still capturing into it", and that entry in `detachedSessions` has `stillCapturedByOtherProcess: true`.

An open `session_open` view of a detached session is closed. DTD disconnects once nothing remains attached.

## Args

- `sessionId` (int, optional): the attached session to detach. Omit when exactly one is attached. Ignored when `all:true`.
- `appNameContains` (string, optional): pick the attached session by app-name substring instead of `sessionId`.
- `all` (bool, optional, default false): detach every attached session.
- `keep` (bool, optional, default false): free the slot but do NOT end the DB session, so it stays open for a later reattach.

## Returns

```json
{
  "detached": true,
  "summary": "Detached from eats_mobile. Session 14 ended ... captured 38 http, 12 log(s), 3 alert(s). Queryable via session_open id:14. DTD disconnected.",
  "wasAttached": true,
  "detachedSessions": [
    {"sessionId": 14, "appName": "eats_mobile",
     "captured": {"http": 38, "logs": 12, "alerts": 3}}
  ],
  "remainingAttached": 0,
  "captured": {"http": 38, "logs": 12, "alerts": 3},
  "nextSteps": [
    "session_open id:14 ...",
    "session_list ...",
    "network_attach ..."
  ]
}
```

In the summary, the session is "ended", "kept open (slot freed)" with `keep:true`, or "stays open: another server process is still capturing into it". With sessions still attached, the summary says how many, and `nextSteps` starts with `network_status`.

When nothing is attached: `{detached:true, summary:"No-op: nothing attached.", wasAttached:false, remainingAttached:0, nextSteps:[network_status, network_attach, session_list]}`.

Errors:
- `errorKind: bad_argument`: several sessions attached and no selector ("Ambiguous detach"), or `appNameContains` matches several sessions (`matches` lists them).
- `errorKind: not_found`: no attached session has that `sessionId`, or no app name contains the substring. `attached` lists what is attached.

## Pairs well with

- `session_list`: confirm the session shows up with `endedMs` set.
- `session_export`: write a HAR from the just-ended session.
- `session_note`: annotate while you remember why this session existed.

## Example

```
> network_detach
< {detached:true, summary:"Detached from eats_mobile. Session 14 ended — captured 38 http, 12 log(s), 3 alert(s)..."}
> session_note id:14 note:"auth bug repro for #1842"
```

Two attached, detach one:
```
> network_detach appNameContains:"app_b"
< {detached:true, detachedSessions:[{sessionId:15, ...}], remainingAttached:1}
```

Shared with another server process:
```
> network_detach
< {summary:"Detached from eats_mobile. Session 14 stays open: another server process is still capturing into it ...",
   detachedSessions:[{sessionId:14, stillCapturedByOtherProcess:true, ...}]}
```
