---
tool: socket_get
description: Detail for a single socket by id.
when_to_use: When socket_list shows a socket id you want to look at more closely.
---

## DO NOT USE THIS TOOL WHEN

- You don't have an id — use `socket_list` first.
- You want payload bytes — sockets never capture payloads.
- You expect this to show packet timing — it returns aggregate byte counts and timestamps, not per-packet detail.

## Use this when

- Confirming a specific socket's open/closed state and byte totals.
- Tracking write/read activity on a long-lived socket over multiple calls.

## How it works

Live: re-fetches the full socket profile and finds the id (cheap; profile is small). History: SQL lookup.

## Args

- `id` (string, required).

## Returns

```json
{"source":"history", "sessionId":14, "id":"...", "socketType":"tcp",
 "address":"...", "port":443, "readBytes":12345, "writeBytes":456, "open":true}
```

## Pairs well with

- `socket_list` — discovery.

## Example

```
> socket_list
> socket_get id:sock-7
```
