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
- You already know the path to the field you need: `network_body_query jsonPath:"..."` extracts it directly.

## Use this when

- A response is 1-2 MB and `network_get`'s first 4 KB is just the opening of one big array (low information per token).
- You need to know the shape (keys, types, array lengths) and WHERE the bytes are, then drill exactly one branch.
- Pairs with the recon -> drill ladder: outline to find the branch, then `network_body_query jsonPath:` to extract it (or `network_body` for raw bytes).

## How it works

Fetches the full body (same live-VM / history path as `network_body`), parses it as JSON, and walks it into a skeleton:

- **scalar** -> a type string: `string` | `number` | `bool` | `null`.
- **array** -> `{type:"array", count:N, bytes:B, element:<skeleton of [0]>}`: only the first element's shape, since arrays are usually homogeneous. An empty array is `{type:"array", count:0, bytes:2}` with no `element`.
- **object** -> `{type:"object", keys:N, bytes:B, fields:{key:<skeleton>}}`, plus `omittedKeys:M` past `maxKeys`.

`bytes` is the minified-JSON byte size of that branch: the signal for where to drill. It is a size, not an offset into the raw body, so drill with `network_body_query jsonPath:` rather than computing `network_body` offsets from it. Beyond `maxDepth`, a container collapses to `{type, count|keys, bytes, truncated:"maxDepth"}`. Non-JSON, non-UTF-8, or a body over the 8 MB outline cap returns `outlineAvailable:false` with a `reason` and a `head` preview (the first `headBytes` bytes as UTF-8).

A body with no bytes returns a normal reply with `totalSize:0` and a `bodyStatus` (`empty`, `pending`, or `unavailable`), same as `network_body`.

Body decryption: when `session_configure bodyDecryption:{...}` is on, the outline is built from the decrypted plaintext and the reply carries `decrypted:true`. A body that does not fit the scheme is outlined as captured, with `decrypted:false` and `decryptionFailed:"<reason>"` (never an error).

## Args

- `id` (string, required).
- `which` (string, default `"response"`): `"response"` | `"request"`.
- `sessionId` (int, optional): session to read. Omit to auto-resolve (the sole attached session, or the one you opened).
- `appNameContains` (string, optional): pick the attached session by app-name substring.
- `isolateId` (string, optional, live only): try only this isolate.
- `maxDepth` (int, default 6): how deep before collapsing a branch. Not clamped.
- `maxKeys` (int, default 60): max object keys to expand per node. Not clamped.
- `headBytes` (int, default 512, cap 4096): leading bytes to preview for non-JSON. 0 or negative means the default.

## Returns

```json
{
  "source": "history",
  "scope": {"sessionId": 14, "isLive": false},
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
    "network_body_query id:\"req-1\" which:response jsonPath:\"$.<branch>\" (extract just the node you need)",
    "network_body_query id:\"req-1\" which:response grep:\"<regex>\" (text-search the body)",
    "network_body id:\"req-1\" which:response offset:0 length:16384 (fetch the actual bytes)"
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

Errors: `bad_argument` (missing `id`, `which` not request/response), `not_found` / `unresponsive_vm` (same body-fetch failures as `network_body`), `internal` (unexpected failure). Scope failures return `no_session` (nothing attached or opened, or no attached session matches `appNameContains`) or `bad_argument` (several attached sessions match), with `nextSteps`.

## Pairs well with

- `network_get`: shows `truncated:true` and suggests this tool first.
- `network_body_query`: extract the branch the outline pointed at.
- `network_body`: raw byte paging when you need the exact bytes.

## Example

```
> network_body_outline id:"req-1"
< {outline:{type:"object", keys:2, bytes:113827, fields:{data:{type:"array", count:1000, bytes:113781, ...}, pagination:{...}}}}
> network_body_query id:"req-1" jsonPath:"$.data[*].name" maxMatches:5
< {totalMatches:1000, matches:[{path:"$.data[0].name", value:"item0"}, ...], truncated:true}
```
