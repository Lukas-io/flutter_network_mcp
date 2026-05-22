---
tool: network_get
description: Full headers + truncated body for a single HTTP request.
when_to_use: After picking an id from network_list or network_search and you want to actually read the request.
---

## DO NOT USE THIS TOOL WHEN

- You don't have an id yet — use `network_list` or `network_search` first.
- You only need metadata (host, method, status) — `network_list` already returned that.
- The body is huge and you only want a slice — call `network_body` with offset/length directly.
- You want to compare two requests — use `network_diff` (it handles bodies + headers in one call).
- You're scripting bulk export — use `session_export` to HAR.

## Use this when

- The user wants to see "what was sent" or "what came back" for a specific request.
- You need to inspect specific headers (Authorization shape, retry-after, content-type).
- You want a quick look at the body that fits in the truncation budget (default 4 KB per side).

## How it works

Live mode: calls `getHttpProfileRequest` on the VM service, which returns full headers + body bytes.

History mode: reads from `http_requests` + `http_bodies` for the viewed session. If the writer hasn't backfilled bodies yet (just after a request completes), bodies will be missing; live mode has them immediately.

Bodies are decoded as UTF-8 for json/text/xml/form content types, base64 otherwise. Truncated payloads return `{truncated:true, totalSize:N}` — call `network_body` for more.

## Args

- `id` (string, required) — request id from `network_list` or `network_search`.
- `includeBodies` (bool, default true) — false to skip bodies entirely.
- `bodyTruncateBytes` (int, default 4096) — `0` or negative = unlimited (use with care).

## Returns

```json
{
  "source": "live",
  "sessionId": 14,
  "id": "...",
  "method": "POST",
  "uri": "...",
  "durationMs": 124,
  "request": {
    "headers": {...},
    "body": {"encoding":"utf8", "size":42, "totalSize":42, "truncated":false, "value":"{...}"}
  },
  "response": {
    "statusCode": 200,
    "headers": {...},
    "body": {"encoding":"utf8", "size":4096, "totalSize":18432, "truncated":true, "value":"..."}
  }
}
```

## Pairs well with

- `network_body` — when `truncated:true`.
- `network_diff` — to compare with another id.
- `network_replay` — to emit a curl reproduction.

## Example

```
> network_get id:abc bodyTruncateBytes:2048
< {response:{body:{truncated:true, totalSize:18432, value:"..."}}}
> network_body id:abc which:response offset:2048 length:16384
```
