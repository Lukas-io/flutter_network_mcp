---
tool: network_diff
description: Structural diff of two captured HTTP requests in the same session.
when_to_use: When you have two captured ids and need to know what's different — status, method, URL, headers, response body hunks.
---

## DO NOT USE THIS TOOL WHEN

- The ids are in different sessions — open the older one first, but the diff only operates within ONE session.
- You only need to know if status changed — `network_list` shows it in summaries.
- One of the bodies is binary — body diff is skipped (the response surfaces this in `warnings`).
- You want a semantic JSON diff — this is line-based. Adequate for pretty-printed JSON; for structural comparisons reach for `network_query`.
- `idA == idB` — the tool errors. You're not diffing anything.

## Use this when

- Same endpoint, working vs broken state ("yesterday vs today's auth call").
- Investigating a regression after a refactor ("did the request body change?").
- Confirming a retry sent identical headers/body.

## How it works

Pulls both `http_requests` rows from the DB. Computes header set diff (added / removed / changed) on the response headers. Tries to decode response bodies as utf8; if both succeed, runs a line-by-line diff with per-line truncation (default 2000 chars). Status/method/URL diffs are reported only when changed.

## Args

- `idA` (string, required).
- `idB` (string, required).
- `sessionId` (int, optional) — defaults to current session.
- `maxBodyLines` (int, default 200, hard cap 1000).
- `maxLineLength` (int, default 2000, hard cap 8000).

## Returns

```json
{
  "sessionId": 14,
  "summary": "POST /v1/login → 500  vs  POST /v1/login → 200  →  differs: status, body.",
  "a": {"id":"x","method":"POST","url":"...","statusCode":500,"durationMs":180},
  "b": {"id":"y","method":"POST","url":"...","statusCode":200,"durationMs":4500},
  "statusDiff": {"a":500, "b":200},
  "responseHeaders": {"added":{}, "removed":{}, "changed":{"content-length":{"a":"40","b":"31"}}},
  "responseBody": {"comparable":true, "equal":false, "truncated":false,
                   "hunks":["- {\"error\":\"x\"}","+ {\"ok\":true}"]},
  "warnings": [],
  "nextSteps": [
    "network_get id:\"x\" — full detail on request A",
    "network_get id:\"y\" — full detail on request B",
    "network_replay id:\"x\" / id:\"y\" — emit curls to reproduce both"
  ]
}
```

`statusDiff` / `methodDiff` / `urlDiff` only appear when changed. `warnings` surfaces body-not-comparable, truncation, and over-long lines.

## Pairs well with

- `network_list` — find the two ids.
- `network_search` — find ids by content match, then diff.
- `network_get` — full detail on either side.
- `network_replay` — reproduce both.

## Example

```
> network_list hostContains:"auth" limit:5
< [{id:"before", statusCode:200}, {id:"after", statusCode:401}]
> network_diff idA:"before" idB:"after"
< {summary:"GET /me → 200 vs GET /me → 401 → differs: status, 1 header, body.",
   statusDiff:{a:200, b:401}, ...}
```
