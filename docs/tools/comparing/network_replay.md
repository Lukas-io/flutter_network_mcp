---
tool: network_replay
description: Emit a runnable curl command for a captured HTTP request. Auth headers shown by default (local repro); body truncated by default.
when_to_use: When the user wants to reproduce a request from the terminal, share it, or test a fix.
---

## DO NOT USE THIS TOOL WHEN

- The user wants to actually re-send the request from inside the app — this tool only emits the command; nothing executes.
- The body is binary — `--data-binary @-` is used; you'd have to pipe the raw bytes yourself. Surfaces in `warnings`.
- You're about to share the curl externally — pass `redact:true` first (default is `false`, since this is a local repro of the user's own traffic and debugging auth needs the real token). The result `warnings` flag when secrets are unredacted.
- HTTP/2-only / gRPC-framed protocols — curl supports HTTP/2 but framed protocols won't round-trip cleanly.

## Use this when

- "Give me a curl I can run" — exactly this. Real auth is included by default so it works as-is.
- Debugging auth (is the token attached? stale? does the replay reproduce the 401?) — needs the real value, which is the default.
- Filing a bug reproducer — pass `redact:true` to mask `authorization`/`cookie`/etc. before sharing.

## How it works

Reads the request from the DB (current session by default). Builds `curl -X METHOD -H 'Name: Value' --data-raw '<body>' '<url>'`. Single-quotes everything; doubles single quotes via the `'\''` trick. With `redact:true`, header values in `dao.redactedHeaderSet()` (built-ins + names added via `redacted_headers`) are masked with `<redacted>`; by default (`redact:false`) real values are shown. Redaction is display-only — the DB always stores the real values; the share boundary that warns about unredacted secrets is `session_export`.

Body is truncated to `bodyTruncateBytes` (default 4 KB) so the response payload stays context-cheap. `bodyTotalSize` + `bodyTruncated` + a top-level warning surface when truncation happened.

## Args

- `id` (string, required).
- `sessionId` (int, optional) — defaults to current session.
- `redact` (bool, default false) — pass `true` to mask auth headers before sharing the curl.
- `bodyTruncateBytes` (int, default 4096, hard cap 262144). Pass 0 to use the hard cap.

## Returns

```json
{
  "sessionId": 14,
  "summary": "POST /v1/login curl emitted (2 header(s), 41-byte body).",
  "id": "req-1",
  "method": "POST",
  "url": "https://...",
  "redacted": false,
  "headerCount": 2,
  "bodyTotalSize": 41,
  "bodyTruncated": false,
  "curl": "curl -X 'POST' -H 'Content-Type: application/json' -H 'Authorization: Bearer eyJ...' --data-raw '...' 'https://...'",
  "warnings": ["Auth headers are NOT redacted (the default for local repro) — pass redact:true before sharing this curl externally."],
  "nextSteps": [
    "Paste the curl into your terminal to reproduce the request",
    "network_diff idA:\"req-1\" idB:\"<other id>\" — compare with another captured request",
    "network_get id:\"req-1\" — see headers + response detail"
  ]
}
```

With `redact:true`, the `Authorization` value becomes `<redacted>`, `redacted:true` + `redactedHeaders:1` appear, and the "not redacted" warning is dropped. `warnings` otherwise appears for: binary body (uses `@-`), body truncated, or (default) unredacted auth.

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
