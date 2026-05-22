---
tool: network_diff
description: Structural diff of two captured HTTP requests. Status, method, URL, headers, and body hunks.
when_to_use: When you have two captured requests and need to know what's different.
---

## DO NOT USE THIS TOOL WHEN

- The two ids are in different sessions — this tool requires both in the same session. Open the older session first, then diff within it.
- You only need to know if the status changed — `network_list` shows status in summaries; eyeball it.
- One of the bodies is binary — body diff only works when both are utf8-decodable. Header diff still runs.
- You want a semantic JSON diff — this is line-based. Adequate for pretty-printed JSON; use `network_query` for structural analysis.
- Both ids are identical and you want a "history" of a single request — this is for comparing two separate captures.

## Use this when

- Comparing the same endpoint between a working and broken state ("yesterday's auth call vs today's").
- Investigating a regression: "the request body changed after the refactor — show me how".
- Confirming a retry attempt sent identical headers/body.

## How it works

Pulls both requests from the DB (session = current or explicit). Computes header set differences (added / removed / changed). Tries to decode response bodies as utf8; if both succeed, runs a line-by-line diff (capped to `maxBodyLines`, default 200). Status, method, URL diffs are reported as before/after pairs.

## Args

- `idA` (string, required) — first request id.
- `idB` (string, required) — second request id.
- `sessionId` (int, optional) — defaults to current session (live or viewed).
- `maxBodyLines` (int, default 200, hard cap 1000).

## Returns

```json
{
  "sessionId": 14,
  "a": {"id":"...","method":"POST","statusCode":500},
  "b": {"id":"...","method":"POST","statusCode":200},
  "statusDiff": {"a":500, "b":200, "changed":true},
  "responseHeaders": {"added":{}, "removed":{}, "changed":{"content-length":{"a":"40","b":"31"}}},
  "responseBody": {"comparable":true, "equal":false, "truncated":false,
                   "hunks":["- {\"error\":\"x\"}","+ {\"ok\":true}"]}
}
```

## Pairs well with

- `network_list` — find the two ids to diff.
- `network_search` — find both ids by matching a string.
- `network_get` — get full detail on either side.

## Example

```
> network_list hostContains:"auth" limit:5
< [{id:before, statusCode:200}, {id:after, statusCode:401}]
> network_diff idA:before idB:after
< {statusDiff:{a:200,b:401}, responseBody:{hunks:[...]}}
```
