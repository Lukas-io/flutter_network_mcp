---
tool: network_body
description: Byte-range fetch of a single request/response body, with summary, warnings, and paging hints.
when_to_use: When network_get reports `truncated:true`, OR when you need a specific slice of a known-large body.
---

## DO NOT USE THIS TOOL WHEN

- The body isn't truncated — `network_get` already returned the whole thing.
- You want to read every byte of a multi-MB body — that's many calls. Use `network_search` to find what you need instead.
- You haven't called `network_get` first — you'll be guessing at offsets. Get `totalSize` first.
- The body is binary and you want JSON — passing `decode:"utf8"` to binary data gives mojibake. Use `decode:"base64"`.
- The session was just attached — bodies aren't backfilled to history yet. Use live mode (no `session_open`) for the first ~5 seconds.

## Use this when

- `network_get` reported `truncated:true` and you need bytes beyond the cap.
- A small window in the middle of a large body.
- Iterating: call, get `nextOffset`, call again until `nextOffset == null`.

## How it works

Live mode: re-fetches the request via VM service and slices.
History mode: reads the `http_bodies` BLOB and slices.

Returns `nextOffset` when more bytes remain. Empty response (no body or 0 bytes) returns a clean `{totalSize:0}` with a warning if the writer hasn't backfilled in history mode.

## Args

- `id` (string, required).
- `which` (string, required) — `"request"` or `"response"`.
- `offset` (int, default 0) — clamped to `[0, totalSize]`.
- `length` (int, default 16384, hard cap 262144).
- `decode` (string, default `"auto"`) — `"auto"` | `"utf8"` | `"base64"`.

## Returns

```json
{
  "source": "history",
  "sessionId": 14,
  "summary": "Returned bytes 4096–20480 of 18432 for response body of req-1 (utf8); call again with offset:20480 for more.",
  "id": "req-1",
  "which": "response",
  "mimeType": "application/json",
  "totalSize": 18432,
  "offset": 4096,
  "returnedSize": 14336,
  "nextOffset": null,
  "encoding": "utf8",
  "value": "..."
}
```

`warnings: []` appears when: history body not yet persisted; offset clamped; utf8 requested on binary.

## Pairs well with

- `network_get` — always run first to learn `totalSize`.
- `network_search` — find content rather than read linearly.
- `network_replay` — once you've got the body, emit a curl.

## Example

```
> network_get id:abc bodyTruncateBytes:4096
< {response:{body:{totalSize:262145, truncated:true}}}
> network_body id:abc which:response offset:0 length:262144
< {nextOffset:262144, summary:"Returned bytes 0–262144 of 262145..."}
> network_body id:abc which:response offset:262144 length:1
< {nextOffset:null}
```
