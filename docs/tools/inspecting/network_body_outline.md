---
tool: network_body_outline
description: Structural skeleton of a large body — keys, value types, array lengths, per-branch byte sizes, no values.
when_to_use: When a JSON body is large and you need its SHAPE (and where the bytes are) before paging the right slice.
---

## DO NOT USE THIS TOOL WHEN

- The body is small — `network_get` already inlined the whole thing.
- You want actual values — this returns structure only. Use `network_body` for the bytes.
- The body is not JSON — you get a content-type + total size + a short head, nothing structural.
- You already know which slice you want — go straight to `network_body`.

## Use this when

- A response is 1-2 MB and `network_get`'s first 4 KB is just the opening of one big array (low information per token).
- You need to know the shape (keys, types, array lengths) and WHERE the bytes are, then drill exactly one branch.
- Pairs with the recon -> drill ladder: outline to find the branch, then `network_body` the slice.

## How it works

Fetches the full body (same live-VM / history path as `network_body`), parses it as JSON, and walks it into a skeleton:

- **scalar** -> a type string: `string` | `number` | `bool` | `null`.
- **array** -> `{type:"array", count:N, bytes:B, element:<skeleton of [0]>}` — only the first element's shape, since arrays are usually homogeneous.
- **object** -> `{type:"object", keys:N, bytes:B, fields:{key:<skeleton>}}`, plus `omittedKeys:M` past `maxKeys`.

`bytes` is the minified-JSON byte size of that branch — the signal for where to drill. Beyond `maxDepth`, a container collapses to `{type, count|keys, bytes, truncated:"maxDepth"}`. Non-JSON (or a body over the 8 MB outline cap) returns `outlineAvailable:false` with a `head` preview.

## Args

- `id` (string, required).
- `which` (string, default `"response"`) — `"response"` | `"request"`.
- `maxDepth` (int, default 6) — how deep before collapsing a branch.
- `maxKeys` (int, default 60) — max object keys to expand per node.
- `headBytes` (int, default 512, cap 4096) — leading bytes to preview for non-JSON.

## Returns

```json
{
  "source": "history",
  "sessionId": 14,
  "summary": "Structural outline of response body for req-1 (113827 bytes, object). No values; `bytes` per branch shows where to drill, then network_body the slice.",
  "id": "req-1",
  "which": "response",
  "bodyStatus": "stored",
  "mimeType": "application/json",
  "totalSize": 113827,
  "outlineAvailable": true,
  "outline": {
    "type": "object",
    "keys": 2,
    "bytes": 113827,
    "fields": {
      "data": {
        "type": "array",
        "count": 1000,
        "bytes": 113781,
        "element": {
          "type": "object",
          "keys": 4,
          "bytes": 110,
          "fields": {
            "id": "number",
            "name": "string",
            "prices": {"type": "array", "count": 10, "bytes": 35, "element": "number"},
            "meta": {"type": "object", "keys": 3, "bytes": 28, "fields": {"a": "number", "b": "string", "c": "bool"}}
          }
        }
      },
      "pagination": {"type": "object", "keys": 2, "bytes": 24, "fields": {"page": "number", "total": "number"}}
    }
  },
  "nextSteps": [
    "network_body id:\"req-1\" which:response offset:0 length:16384 — fetch the actual bytes of a branch"
  ]
}
```

Non-JSON body:

```json
{
  "outlineAvailable": false,
  "reason": "not valid JSON (FormatException)",
  "head": "<!doctype html><html>...",
  "totalSize": 40213,
  "nextSteps": ["network_body id:\"req-1\" which:response — page the raw bytes"]
}
```

The `bytes` annotation is the point: in the example, 113781 of 113827 bytes live in `data`, so that's the branch to page — not `pagination`.
