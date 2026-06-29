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

## Modes (exactly one)

### `grep:"<regex>"`

Dart `RegExp` over the decoded text body. Returns up to `maxMatches` matches, each with the char `offset`, the matched text, and a `context` window. Reports `totalMatches` and `truncated`. Refused on bodies over 16 MB (page instead).

### `jsonPath:"<path>"`

Extracts nodes from a JSON body. Supported syntax (deliberately small):

- `$.a.b` / `a.b` — dotted keys (leading `$`/`.` optional).
- `a[0].b` — array index.
- `a['b']` / `a["b"]` — bracket key.
- `a[*].b` — wildcard: a field across every array element (or every value of a map). Wildcards resolve to concrete paths in the output (`data[3].symbol`).

NOT supported: filter predicates `[?(@.x=='y')]`, slices, recursive descent `..`. For value-matching, use `grep` (e.g. `grep:"\"symbol\":\"tsla\""`). A matched node larger than ~2 KB is returned as `{path, valueBytes, truncated:true, outline:<skeleton>}` instead of inline, so the result stays bounded.

## Args

- `id` (string, required).
- `which` (string, default `"response"`).
- `grep` (string) — regex mode. Mutually exclusive with `jsonPath`.
- `jsonPath` (string) — path mode. Mutually exclusive with `grep`.
- `ignoreCase` (bool, default false) — grep only.
- `maxMatches` (int, default 20).
- `context` (int, default 80) — grep context chars per side.

## Returns

```json
// jsonPath:"$.data[*].symbol" over a 1000-element array
{
  "id": "req-1",
  "which": "response",
  "mode": "jsonPath",
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

The recon -> drill ladder for one big body: `network_body_outline` (find the branch) -> `network_body_query` (extract it) -> `network_body` (raw bytes if you still need them).
