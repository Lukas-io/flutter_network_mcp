---
tool: network_body_query
description: Search or extract WITHIN one captured body — regex grep or a JSON path — returning only the matching slice(s).
when_to_use: When you're on one large body and need a field deep inside it, without paging the whole thing into context.
---

## DO NOT USE THIS TOOL WHEN

- You're trying to FIND the request — that's `network_search` (cross-request BM25).
- You want the whole body — that's `network_body` (byte paging) or `network_get`.
- You don't know the body's shape yet — run `network_body_outline` first, then query the branch.

## Use this when

- A 1-2 MB JSON response and you need one field deep inside — `jsonPath` extracts just that node.
- You need every value of a field across a big array — `jsonPath:"$.data[*].symbol"`.
- A text or non-JSON body and you need the lines around a token — `grep` with context windows.

## How it works

Fetches the full body the same way as `network_body` (live VM with a DB fallback, or history), then runs exactly one of two modes. A body with no bytes returns a normal reply with `totalSize:0` and a `bodyStatus` (`empty`, `pending`, or `unavailable`) instead of matches.

Body decryption: when `session_configure bodyDecryption:{...}` is on, grep and jsonPath run on the decrypted plaintext and the reply carries `decrypted:true`. A body that does not fit the scheme is queried as captured, with `decrypted:false` and `decryptionFailed:"<reason>"` (never an error).

### `grep:"<regex>"`

Dart `RegExp` (multi-line mode) over the body decoded as UTF-8. A leading `(?i)` is accepted and turns on case-insensitive matching. Returns up to `maxMatches` matches, each with the character `offset`, the matched text (capped at 512 chars), and a `context` window. Reports `totalMatches`, and `truncated:true` when more matched than were returned. Refused with `bad_argument` on bodies over 16 MB (page instead).

The `offset` counts characters of the decoded text. The suggested `network_body` step reuses it as a byte offset, which lands in the same place only for ASCII bodies.

### `jsonPath:"<path>"`

Extracts nodes from a JSON body. Supported syntax (deliberately small):

- `$.a.b` / `a.b` — dotted keys (leading `$`/`.` optional).
- `a[0].b` — array index.
- `a['b']` / `a["b"]` — bracket key.
- `a[*].b`: wildcard, a field across every array element (or every value of a map). Wildcards resolve to concrete paths in the output: `$.data[3].symbol` for an array, `$.prices['usd']` for a map.

NOT supported: filter predicates `[?(@.x=='y')]`, slices, recursive descent `..`. For value-matching, use `grep` (e.g. `grep:"\"symbol\":\"tsla\""`). A matched node whose JSON encoding is over 2048 chars is returned as `{path, valueBytes, truncated:true, outline:<skeleton, maxDepth 3>}` instead of inline, so the result stays bounded. A body that is not valid JSON fails with `bad_argument` (use `grep`); a malformed path fails with `bad_argument` and the parser's message.

## Args

- `id` (string, required).
- `which` (string, default `"response"`): `"response"` | `"request"`.
- `grep` (string): regex mode. Exactly one of `grep` / `jsonPath` is required.
- `jsonPath` (string): path mode. Exactly one of `grep` / `jsonPath` is required.
- `ignoreCase` (bool, default false): grep only.
- `maxMatches` (int, default 20): values below 1 mean the default. No upper cap.
- `context` (int, default 80): grep context chars per side. Negative means the default.
- `sessionId` (int, optional): session to read. Omit to auto-resolve.
- `appNameContains` (string, optional): pick the attached session by app-name substring.
- `isolateId` (string, optional, live only): try only this isolate.

## Returns

```json
// jsonPath:"$.data[*].symbol" over a 1000-element array
{
  "source": "history",
  "scope": {"sessionId": 14, "isLive": false},
  "sessionId": 14,
  "summary": "jsonPath $.data[*].symbol matched 1000 node(s) in response body of req-1 (showing 20).",
  "id": "req-1",
  "which": "response",
  "mode": "jsonPath",
  "mimeType": "application/json",
  "totalSize": 113827,
  "totalMatches": 1000,
  "matches": [
    {"path": "$.data[0].symbol", "value": "aapl"},
    {"path": "$.data[1].symbol", "value": "tsla"}
  ],
  "truncated": true,
  "nextSteps": ["network_body_outline id:<id> — see the full structure if the path missed"]
}
```

```json
// grep:"\"name\":\"item7\""
{
  "mode": "grep",
  "totalMatches": 1,
  "matches": [{"offset": 787, "match": "\"name\":\"item7\"", "context": "...id\":7,\"name\":\"item7\",\"prices\":[..."}],
  "nextSteps": ["network_body id:\"req-1\" which:response offset:787 length:16384 — read full bytes around the first match"]
}
```

The grep reply has no `nextSteps` entry when nothing matched.

Errors: `bad_argument` (missing `id`, bad `which`, neither or both of `grep` / `jsonPath`, invalid regex, body over the 16 MB grep cap, non-JSON body in jsonPath mode, malformed path), `not_found` / `unresponsive_vm` (same body-fetch failures as `network_body`), `internal` (unexpected failure). Scope failures return `no_session` (nothing attached or opened, or no attached session matches `appNameContains`) or `bad_argument` (several attached sessions match), with `nextSteps`.

The recon -> drill ladder for one big body: `network_body_outline` (find the branch) -> `network_body_query` (extract it) -> `network_body` (raw bytes if you still need them).

## Pairs well with

- `network_body_outline`: learn the shape and pick the path first.
- `network_search`: find which request holds the content, then query inside its body.
- `network_body`: raw bytes around a grep hit.

## Example

```
> network_body_outline id:"req-1"
< {outline:{type:"object", fields:{data:{type:"array", count:1000, ...}}}}
> network_body_query id:"req-1" jsonPath:"$.data[*].symbol" maxMatches:3
< {totalMatches:1000, matches:[{path:"$.data[0].symbol", value:"aapl"}, ...], truncated:true}
> network_body_query id:"req-1" grep:"\"symbol\":\"tsla\""
< {totalMatches:1, matches:[{offset:5120, match:"\"symbol\":\"tsla\"", context:"..."}]}
```
