---
tool: network_search
description: Full-text search across captured HTTP urls + request/response bodies (SQLite FTS5), with BM25 ranking.
when_to_use: When the user describes a symptom in plain language ("auth failed", "rate_limit") and you need to find the requests that contain that string.
---

## DO NOT USE THIS TOOL WHEN

- The session is freshly attached — bodies haven't been backfilled yet (wait ~5s after request completion).
- You only need to filter by host/method/status — `network_list` does that without a full-text scan.
- You already have a specific id — use `network_get`.
- The match is structural (header present, status range, time window) — use `network_query` with SQL.
- You want operator semantics (AND, OR, NEAR) — by default the query is phrase-quoted to escape special chars. Compose multiple search calls or use raw FTS5 syntax via `network_query`.

## Use this when

- "Find the request whose response had 'invalid_token'" — exactly this.
- Searching history for a token you remember by content.
- The user pasted an error message — "where did this come from?"

## How it works

Wraps the user query as an FTS5 phrase (`"..."`) so `-`, `:`, `(`, etc. don't trip the parser. Matches against `http_search` (url + content_request + content_response), joins back to `http_requests` via `http_search_map`. Ranked by BM25 (lowest rank = best match). Snippets are 12-token windows with «highlights».

Only requests whose bodies have been INDEXED appear. Bodies index when the capture writer backfills them (~2s tick) AND the content type is text/json/xml/form. Binary bodies are never indexed.

## Args

- `query` (string, required) — phrase-searched by default.
- `sessionId` (int, optional) — defaults to current session.
- `which` (string, default `"any"`) — `"url"` | `"request"` | `"response"` | `"any"`.
- `limit` (int, default 20, hard cap 100).

## Returns

```json
{
  "sessionId": 14,
  "summary": "1 match(es) for \"invalid_token\" in session 14 (ranked by BM25).",
  "query": "invalid_token",
  "which": "any",
  "count": 1,
  "matches": [
    {"sessionId":14, "id":"req-1", "method":"POST",
     "url":"https://api.example.com/v1/login", "statusCode":500,
     "snippet":"{\"error\":\"«invalid_token»\",\"message\":\"auth failed\"}",
     "rank": -1.2e-06}
  ],
  "nextSteps": [
    "network_get id:\"req-1\" — full headers + body for the top match"
  ]
}
```

Empty results include a `warnings` array suggesting backfill delay or query specificity.

## Pairs well with

- `network_get` — pass the matched id for full detail.
- `session_open` — search inside a specific historical session.
- `network_diff` — once you have two matching ids.
- `network_list` — when metadata filtering is more direct.

## Example

```
> network_search query:"invalid_token"
< {summary:"1 match(es)...", matches:[{id:"req-1", snippet:"{...«invalid_token»..."}]}
> network_get id:"req-1"
```
