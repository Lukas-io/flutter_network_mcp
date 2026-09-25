---
tool: socket_get
description: Detail for a single dart:io socket by id (no payloads — byte counts + lifetime timing only).
when_to_use: When socket_list returns an id worth inspecting more closely.
---

## DO NOT USE THIS TOOL WHEN

- You don't have an id — use `socket_list` first.
- You expect payload bytes — sockets never capture payloads.
- You expect per-packet timing — this returns aggregate byte counts and lifetime timestamps, not per-packet detail.
- You want to compare two sockets — there is no `socket_diff`. Read both via `socket_get`.

## Use this when

- Confirming a specific socket's open/closed state and byte totals.
- Tracking write/read activity on a long-lived socket across calls.

## How it works

The session resolves like `socket_list` (`sessionId`, else `appNameContains`, else the `session_open` view, else the sole attached session, else a default pick among several attached).

Live (the scope is a session attached to this server): re-fetches the socket profile and finds the id (cheap; profile is small). It reads the isolate named by `isolateId`, else the isolate recorded for this socket in the DB, else every HTTP-profiling isolate. If the socket is no longer in the live profile (closed/collected) or every isolate read failed, it returns the persisted DB copy with `source: "live-db-fallback"`, `degraded: true`, and the reason in `warnings`.

History (a `session_open` view, or an explicit `sessionId` not attached here): single-row SQL lookup on `socket_events`.

## Args

- `id` (string, required): socket id from `socket_list`.
- `sessionId` (int, optional): session to read. Omit to auto-resolve.
- `appNameContains` (string, optional): pick an attached session by app-name substring instead of `sessionId`; must match exactly one.
- `isolateId` (string, optional): isolate to read in live mode. Omit to auto-resolve.

## Returns

```json
{
  "source": "history",
  "scope": {"sessionId": 14, "isLive": false},
  "sessionId": 14,
  "isolateId": "isolates/1234",
  "summary": "TCP api.example.com:443 — 12345 bytes read, 456 bytes written (open).",
  "id": "...",
  "socketType": "tcp",
  "address": "api.example.com",
  "port": 443,
  "startTimeUs": 1700...,
  "readBytes": 12345,
  "writeBytes": 456,
  "open": true,
  "nextSteps": [
    "socket_list — see sibling sockets in this session",
    "network_list hostContains:\"api.example.com\" — check correlated HTTP traffic",
    "Re-call this tool later to see updated read/write bytes (socket is still open)"
  ]
}
```

Null timing fields (`startTimeUs` in history, `endTimeUs`, `lastReadTimeUs`, `lastWriteTimeUs`) and a null `isolateId` are omitted. The `network_list hostContains:` nextStep needs the http capability and a known address; the re-call hint appears only while the socket is open.

Errors: missing `id` returns `bad_argument`. Socket profiling off for a live session returns `capability_disabled`. An id found neither live nor in the DB returns `not_found` (history, or live with `triedIsolates`); in live mode, when every isolate read failed and there is no DB copy, it returns `unresponsive_vm` with `triedIsolates`. Scope failures (nothing attached or opened, no `appNameContains` match, several matches) return an error with `nextSteps` but no `errorKind`.

## Pairs well with

- `socket_list` — discovery.
- `network_list hostContains:` — correlate to HTTP.

## Example

```
> socket_list
< {sockets:[{id:"sock-7", address:"api.x.com"}]}
> socket_get id:"sock-7"
< {summary:"TCP api.x.com:443 — 12345 bytes read..."}
```
