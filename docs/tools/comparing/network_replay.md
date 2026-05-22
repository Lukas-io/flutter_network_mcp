---
tool: network_replay
description: Emit a runnable curl command for a captured HTTP request. Auth headers redacted by default, body truncated by default.
when_to_use: When the user wants to reproduce a request from the terminal, share it, or test a fix.
---

## DO NOT USE THIS TOOL WHEN

- The user wants to actually re-send the request from inside the app — this tool only emits the command; nothing executes.
- The body is binary — `--data-binary @-` is used; you'd have to pipe the raw bytes yourself. Surfaces in `warnings`.
- The request will fail without the redacted Bearer/Cookie AND the user is sharing externally — leave `redact:true` (default). Only set `redact:false` for local debugging.
- HTTP/2-only / gRPC-framed protocols — curl supports HTTP/2 but framed protocols won't round-trip cleanly.

## Use this when

- "Give me a curl I can run" — exactly this.
- Filing a bug reproducer (default `redact:true` keeps secrets out).
- Debugging server-side and bypassing the app.

## How it works

Reads the request from the DB (current session by default). Builds `curl -X METHOD -H 'Name: Value' --data-raw '<body>' '<url>'`. Single-quotes everything; doubles single quotes via the `'\''` trick. Redacts header values from `dao.redactedHeaderSet()` (built-ins + names added via `redacted_headers`).

Body is truncated to `bodyTruncateBytes` (default 4 KB) so the response payload stays context-cheap. `bodyTotalSize` + `bodyTruncated` + a top-level warning surface when truncation happened.

## Args

- `id` (string, required).
- `sessionId` (int, optional) — defaults to current session.
- `redact` (bool, default true).
- `bodyTruncateBytes` (int, default 4096, hard cap 262144). Pass 0 to use the hard cap.

## Returns

```json
{
  "sessionId": 14,
  "summary": "POST /v1/login curl emitted (2 header(s), 1 redacted, 41-byte body).",
  "id": "req-1",
  "method": "POST",
  "url": "https://...",
  "redacted": true,
  "headerCount": 2,
  "redactedHeaders": 1,
  "bodyTotalSize": 41,
  "bodyTruncated": false,
  "curl": "curl -X 'POST' -H 'Content-Type: application/json' -H 'Authorization: <redacted>' --data-raw '...' 'https://...'",
  "nextSteps": [
    "Paste the curl into your terminal to reproduce the request",
    "network_diff idA:\"req-1\" idB:\"<other id>\" — compare with another captured request",
    "network_get id:\"req-1\" — see headers + response detail"
  ]
}
```

`warnings: []` appears when: binary body (uses `@-`), body truncated, redact disabled.

## Pairs well with

- `network_get` — see what's in the request before deciding to replay.
- `network_diff` — replay both sides of a regression.
- `redacted_headers action:add` — extend the redaction set with project-specific header names.

## Example

```
> network_replay id:"req-1"
< {summary:"POST /v1/login curl emitted (2 header(s), 1 redacted, 41-byte body).",
   curl:"curl -X 'POST' -H '... Authorization: <redacted>' ...",
   nextSteps:[...]}
> # paste, fill in the redacted auth, run
```
