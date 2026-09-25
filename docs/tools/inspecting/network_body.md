---
tool: network_body
description: Byte-range fetch of a single request/response body, with summary, warnings, and paging hints.
when_to_use: When network_get reports `truncated:true`, OR when you need a specific slice of a known-large body.
---

## DO NOT USE THIS TOOL WHEN

- The body isn't truncated — `network_get` already returned the whole thing.
- You want to read every byte of a multi-MB body: that's many calls. Use `network_body_query` (inside this body) or `network_search` (across requests) to find what you need instead.
- You haven't called `network_get` first — you'll be guessing at offsets. Get `totalSize` first.
- The body is binary and you want JSON — passing `decode:"utf8"` to binary data gives mojibake. Use `decode:"base64"`.
- You are viewing history for a session that is still capturing and the body reports `bodyStatus:"pending"`: the async backfill has not run yet. Retry in ~2s, or read in live mode (`session_close`).

## Use this when

- `network_get` reported `truncated:true` and you need bytes beyond the cap.
- A small window in the middle of a large body.
- Iterating: call, get `nextOffset`, call again until the reply has no `nextOffset`.

## How it works

Live mode: re-fetches the request via VM service (the `isolateId` you pass, else the isolate recorded in the DB, else every HTTP-profiling isolate) and slices. If the live fetch fails but the body is persisted, it slices the DB copy instead: `source:"live-db-fallback"` plus a warning.
History mode: reads the `http_bodies` BLOB and slices.

Slices are byte-exact (no semantic truncation). `offset` and the returned range refer to the raw body bytes. Returns `nextOffset` when more bytes remain; it is omitted on the last chunk.

No bytes for the body: a normal (non-error) reply with `totalSize:0` and a `bodyStatus`: `empty` (the message had no body), `pending` (not backfilled yet: retry in ~2s, or the session ended first and the bytes are gone), or `unavailable` (lost before capture, with `fetchAttempts` + `reason`). `pending` and `unavailable` add a warning.

Body decryption: when `session_configure bodyDecryption:{...}` is on, the body is decrypted first, the reply carries top-level `decrypted:true`, and `totalSize` / `offset` / `nextOffset` count plaintext bytes. A body that does not fit the scheme is paged as captured, with `decrypted:false` and `decryptionFailed:"<reason>"` (never an error).

## Args

- `id` (string, required).
- `which` (string, required): `"request"` or `"response"`.
- `sessionId` (int, optional): session to read. Omit to auto-resolve (the sole attached session, or the one you opened).
- `appNameContains` (string, optional): pick the attached session by app-name substring.
- `isolateId` (string, optional, live only): try only this isolate.
- `offset` (int, default 0): clamped to `[0, totalSize]`.
- `length` (int, default 16384, hard cap 262144): 0 or negative means the default.
- `decode` (string, default `"auto"`): `"auto"` (utf8 for text content types, base64 otherwise) | `"utf8"` (forced, malformed bytes replaced) | `"base64"`.

## Returns

```json
{
  "source": "history",
  "scope": {"sessionId": 14, "isLive": false},
  "sessionId": 14,
  "summary": "Returned bytes 0–16384 of 40960 for response body of req-1 (utf8); call again with offset:16384 for more.",
  "id": "req-1",
  "which": "response",
  "bodyStatus": "stored",
  "mimeType": "application/json",
  "totalSize": 40960,
  "offset": 0,
  "returnedSize": 16384,
  "nextOffset": 16384,
  "encoding": "utf8",
  "value": "...",
  "nextSteps": ["network_body id:\"req-1\" which:response offset:16384 length:16384 (page next chunk)"]
}
```

On the last chunk `nextOffset` is absent and `nextSteps` offer `network_replay` and `network_diff` instead. `warnings` appears for: a live-to-DB fallback, and an `offset` past `totalSize` (clamped to the end).

Errors: `bad_argument` (missing `id`, `which` not request/response, bad `decode`), `not_found` (unknown id in the viewed session, or unknown to both the live VM and the DB), `unresponsive_vm` (no HTTP-profiling isolates, or the live fetch failed and nothing is persisted), `internal` (unexpected failure). Scope failures return `error` + `nextSteps` without an `errorKind`.

## Pairs well with

- `network_get` — always run first to learn `totalSize`.
- `network_body_outline` / `network_body_query`: on a large JSON body, find or extract the branch instead of paging it all.
- `network_search` — find content rather than read linearly.
- `network_replay` — once you've got the body, emit a curl.

## Example

```
> network_get id:abc bodyTruncateBytes:4096
< {response:{body:{totalSize:262145, truncated:true}}}
> network_body id:abc which:response offset:0 length:262144
< {nextOffset:262144, summary:"Returned bytes 0–262144 of 262145..."}
> network_body id:abc which:response offset:262144 length:1
< {summary:"Returned 1-byte response body for abc (full, ...)"}  (no nextOffset: done)
```
