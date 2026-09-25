---
tool: network_replay
description: Emit a runnable curl command for a captured HTTP request. Auth headers redacted by default; body truncated by default.
when_to_use: When the user wants to reproduce a request from the terminal, share it, or test a fix.
---

## DO NOT USE THIS TOOL WHEN

- The user wants to actually re-send the request from inside the app — this tool only emits the command; nothing executes.
- The body is binary — `--data-binary @-` is used; you'd have to pipe the raw bytes yourself. Surfaces in `warnings`.
- You need a curl that authenticates as-is: the default (`redact:true`) masks auth headers as `<redacted>`. Pass `redact:false` only for a local auth repro, and do not share that output; the result `warnings` flag when secrets are unredacted.
- HTTP/2-only / gRPC-framed protocols — curl supports HTTP/2 but framed protocols won't round-trip cleanly.

## Use this when

- "Give me a curl I can run": exactly this. Auth headers come out as `<redacted>` by default; fill them in, or pass `redact:false`.
- Debugging auth (is the token attached? stale? does the replay reproduce the 401?): pass `redact:false` to get the real value.
- Filing a bug reproducer: the default output already masks auth headers. The body is not redacted, so check it for secrets (a login password, for example) before sharing.

## How it works

Reads the request row and request body from the DB (live or history; the VM is not queried, so a request that is not persisted yet is `not_found`). Builds `curl -X 'METHOD' -H 'Name: Value' --data-raw '<body>' '<url>'`. Single-quotes everything; escapes single quotes via the `'\''` trick. With `redact` unset or `true`, header values whose names are in the redaction set (`authorization`, `cookie`, `proxy-authorization`, `set-cookie`, `x-api-key`, `x-auth-token`, plus names added via `redacted_headers`) are masked with `<redacted>`; with `redact:false` real values are shown. Redaction is display-only: the DB always stores the real values.

Body is truncated to `bodyTruncateBytes` (default 4 KB) so the response payload stays context-cheap. `bodyTotalSize` + `bodyTruncated` + a top-level warning surface when truncation happened. A body that is not valid UTF-8 after truncation becomes `--data-binary @-` with `bodyIsBinary:true`.

The body is always the original captured bytes: `session_configure bodyDecryption` does not apply here, so an encrypted body is replayed encrypted, as the app sent it.

## Args

- `id` (string, required).
- `sessionId` (int, optional): session to read. Omit to auto-resolve (the sole attached session, or the one you opened).
- `appNameContains` (string, optional): pick the attached session by app-name substring.
- `redact` (bool, default true): pass `false` to include real auth header values.
- `bodyTruncateBytes` (int, default 4096, hard cap 262144). Pass 0 (or a negative number) to use the hard cap.

## Returns

```json
{
  "scope": {"sessionId": 14, "isLive": false},
  "sessionId": 14,
  "summary": "POST https://api.example.com/v1/login curl emitted (2 header(s), 1 redacted, 41-byte body).",
  "id": "req-1",
  "method": "POST",
  "url": "https://api.example.com/v1/login",
  "redacted": true,
  "headerCount": 2,
  "redactedHeaders": 1,
  "bodyTotalSize": 41,
  "bodyTruncated": false,
  "curl": "curl -X 'POST' -H 'Content-Type: application/json' -H 'Authorization: <redacted>' --data-raw '...' 'https://api.example.com/v1/login'",
  "nextSteps": [
    "Paste the curl into your terminal to reproduce the request",
    "network_diff idA:\"req-1\" idB:\"<other id>\" — compare with another captured request",
    "network_get id:\"req-1\" — see headers + response detail"
  ]
}
```

With `redact:false`, the real `Authorization` value is in the curl, `redacted:false`, `redactedHeaders` is absent, and a warning says auth headers are NOT redacted. `warnings` otherwise appears for: binary body (uses `@-`) and body truncated. `bodyTotalSize` / `bodyTruncated` are absent when the request had no body.

Errors: `bad_argument` (missing `id`), `not_found` (id not in the session's DB), `internal` (unexpected failure). Scope failures return `no_session` (nothing attached or opened, or no attached session matches `appNameContains`) or `bad_argument` (several attached sessions match), with `nextSteps`.

## Pairs well with

- `network_get` — see what's in the request before deciding to replay.
- `network_diff` — replay both sides of a regression.
- `network_replay_as_test`: the same request as a runnable Dart test.
- `redacted_headers action:add` — extend the redaction set with project-specific header names.

## Example

```
> network_replay id:"req-1"
< {summary:"POST /v1/login curl emitted (2 header(s), 1 redacted, 41-byte body).",
   curl:"curl -X 'POST' -H '... Authorization: <redacted>' ...",
   nextSteps:[...]}
> # paste, fill in the redacted auth (or re-run with redact:false), run
```
