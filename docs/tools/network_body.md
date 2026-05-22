---
tool: network_body
description: Byte-range fetch of a single request or response body. Hard cap 256 KB per call.
when_to_use: After network_get reports truncated:true and you need more of the body, OR you want a specific slice of a known-large body.
---

## DO NOT USE THIS TOOL WHEN

- The body isn't truncated — `network_get` already returned the whole thing.
- You want to read every byte of a 10 MB body — that's 40+ calls. Reconsider: do you actually need every byte? Searching with `network_search` is usually faster.
- You haven't called `network_get` first — you'll be guessing at offsets blindly. Get the `totalSize` first.
- The body is binary and you want JSON — passing `decode:"utf8"` to binary data gives mojibake. Use `decode:"base64"`.

## Use this when

- `network_get` reported `truncated:true` and you need bytes beyond the truncation point.
- You want a small window in the middle of a large body (e.g., bytes 8192-16384).
- You're iterating a large response — call once, get `nextOffset`, call again until null.

## How it works

Live mode: re-fetches the request via VM service and slices the resulting bytes.
History mode: reads the `http_bodies` row for the session and slices the BLOB.

Returns the requested byte range, the original `totalSize`, and `nextOffset` (the offset of the byte after the returned slice, or null if you've read to the end).

## Args

- `id` (string, required).
- `which` (string, required) — `"request"` or `"response"`.
- `offset` (int, default 0).
- `length` (int, default 16384, hard cap 262144).
- `decode` (string, default `"auto"`) — `"auto"` | `"utf8"` | `"base64"`.

## Returns

```json
{
  "source": "history",
  "sessionId": 14,
  "id": "...",
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

## Pairs well with

- `network_get` — always run this first to learn `totalSize`.
- `network_search` — to find what's in the body without reading it linearly.

## Example

```
> network_get id:abc bodyTruncateBytes:0
< {response:{body:{totalSize:262145, truncated:true}}}
> network_body id:abc which:response offset:0 length:262144
< {nextOffset:262144}
> network_body id:abc which:response offset:262144 length:1
< {nextOffset:null}
```
