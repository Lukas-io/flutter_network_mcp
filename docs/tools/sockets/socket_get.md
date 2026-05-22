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

Live: re-fetches the full socket profile and finds the id (cheap; profile is small).
History: single-row SQL lookup.

## Args

- `id` (string, required).

## Returns

```json
{
  "source": "history",
  "sessionId": 14,
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

Null timing fields are omitted.

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
