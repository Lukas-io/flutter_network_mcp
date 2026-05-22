---
tool: network_replay
description: Emit a runnable curl command for a captured HTTP request. Auth headers redacted by default.
when_to_use: When the user wants to reproduce a request from the terminal, share it with a teammate, or test a fix.
---

## DO NOT USE THIS TOOL WHEN

- The user wants to actually re-send the request from inside the app — this tool only emits the command; it doesn't execute anything.
- The body is binary — curl emits `--data-binary @-` and you have no way to pipe the bytes through MCP. Use `network_get` + manual handling.
- The request will fail without the redacted Bearer/Cookie and the user is just going to paste this into a shared doc — leave `redact:true` (the default). Only set `redact:false` for local debugging.
- The request has special transport requirements (HTTP/2, gRPC framing) — curl can do HTTP/2 with `--http2` but framed protocols won't round-trip.

## Use this when

- "Give me a curl I can run" — exactly what this is for.
- Sharing a reproducer in a bug ticket (`redact:true` keeps secrets out).
- Debugging server-side and want to bypass the app entirely.

## How it works

Reads the request from the DB (current session by default). Builds a `curl -X METHOD -H 'Name: Value' --data-raw '<body>' '<url>'` command. Single-quotes everything; doubles single-quote characters via the standard `'\''` trick. Redacts header values for `Authorization`, `Cookie`, `Proxy-Authorization`, `X-API-Key`, `X-Auth-Token` when `redact:true`.

## Args

- `id` (string, required).
- `sessionId` (int, optional) — defaults to current session.
- `redact` (bool, default true).

## Returns

```json
{
  "sessionId": 14,
  "id": "...",
  "method": "POST",
  "url": "https://...",
  "redacted": true,
  "curl": "curl -X 'POST' -H 'Content-Type: application/json' -H 'Authorization: <redacted>' --data-raw '...' 'https://...'"
}
```

## Pairs well with

- `network_get` — to see what's actually in the request before deciding to replay.
- `network_diff` — when you want to replay BOTH sides of a regression.

## Example

```
> network_replay id:abc
< {curl: "curl -X 'POST' -H 'Authorization: <redacted>' ..."}
> # paste into terminal, fill in the auth header, run
```
