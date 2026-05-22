---
tool: network_search
description: Full-text search across captured HTTP urls + request/response bodies (SQLite FTS5).
when_to_use: When the user describes a symptom in plain language ("auth failed", "rate_limit") and you need to find the requests that contain that string.
---

## DO NOT USE THIS TOOL WHEN

- The session is freshly attached and bodies haven't been backfilled yet (wait ~5 seconds after the request completes — body backfill is on a 2-second tick).
- You only need to filter by host/method/status — `network_list` does that without a full-text scan.
- You already have a specific id — use `network_get` directly.
- The match is structural (header present, status range, time window) — use `network_query` with SQL.
- The query has FTS5 operator syntax you want preserved (AND, OR, NEAR, column filters) — by default the query is phrase-quoted to escape special chars. Tear apart the operators yourself and chain `network_search` calls if you want operator behavior.

## Use this when

- "Find the request where the response had 'invalid_token'" — exactly this.
- Searching across history for a token you remember by content.
- The user pasted an error message and asked "where did this come from?".

## How it works

User query is wrapped as an FTS5 phrase (`"query"`) so characters like `-`, `:`, `(` don't trip the FTS5 parser. Matches the FTS5 virtual table `http_search` (url + content_request + content_response), joins back via `http_search_map` to `http_requests`. Results are ranked by BM25, lowest rank = best match. Returns a 12-token-window snippet with «…» highlights.

Only requests whose bodies have been indexed appear in results. Bodies are indexed when the capture writer backfills them (every 2s) AND the content type is text/json/xml/form. Binary bodies are never indexed.

## Args

- `query` (string, required) — phrase-search by default.
- `sessionId` (int, optional) — defaults to current session.
- `which` (string, optional) — `"any"` (default) | `"url"` | `"request"` | `"response"`.
- `limit` (int, default 20, hard cap 100).

## Returns

```json
{
  "sessionId": 14,
  "query": "invalid_token",
  "which": "any",
  "count": 1,
  "matches": [
    {"sessionId":14, "id":"req-1", "method":"POST",
     "url":"https://api.example.com/v1/login", "statusCode":500,
     "snippet":"{\"error\":\"«invalid_token»\",\"message\":\"auth failed\"}",
     "rank": -1.2e-06}
  ]
}
```

## Pairs well with

- `network_get` — pass the matched id for full detail.
- `session_open` — search inside a specific historical session.
- `network_diff` — once you have two matching ids, compare them.

## Example

```
> network_search query:"invalid_token" limit:5
< [{id:req-1, snippet:"{...«invalid_token»..."}]
> network_get id:req-1
```
