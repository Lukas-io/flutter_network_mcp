---
tool: network_list
description: Paginated HTTP request summaries with filters. Bodies NOT included.
when_to_use: To find requests by metadata (host, method, status, time range) and get ids you can pass to other tools.
---

## DO NOT USE THIS TOOL WHEN

- You need full request data — use `network_get` after picking an id from this list.
- You're looking for a string inside bodies — use `network_search`. This tool only sees metadata.
- You already have a specific request id — call `network_get` directly.
- You want bodies in the result — they're never returned by list. Sizes only.
- You're polling without a cursor — pass `since` from a prior `nextCursor` to skip what you've seen.

## Use this when

- The user asks "what requests has the app made?" — start here, paginate down.
- Looking for failures: `statusMin: 400`.
- Looking for traffic to a specific service: `hostContains: "api.example"`.
- Polling incrementally: pass `since: <prior nextCursor>`.

## How it works

Live mode (no `session_open`): calls `getHttpProfile` on the VM service, sorts newest-first, applies filters, returns summaries. Updates the session cursor so the next call without `since` returns only NEW activity.

History mode (after `session_open`): runs an indexed SQL query against `http_requests` for the viewed session.

## Args

- `since` (int) — microsecond cursor (live: from prior `nextCursor`; history: start_us threshold).
- `method` (string[]) — `["GET", "POST"]`.
- `hostContains` (string) — case-insensitive substring on host.
- `statusMin` / `statusMax` (int).
- `limit` (int) — default 50, hard cap 200.

## Returns

```json
{
  "source": "live",
  "sessionId": 14,
  "count": 5,
  "nextCursor": 1700000000000000,
  "requests": [
    {"id": "...", "method": "POST", "uri": "...", "host": "...", "path": "...",
     "statusCode": 200, "durationMs": 124, "responseContentLength": 4521,
     "responseContentType": "application/json", "hasError": false}
  ]
}
```

## Pairs well with

- `network_get` — for full details on any id.
- `network_search` — when filtering by metadata isn't enough.
- `network_diff` — to compare two ids returned here.

## Example

```
> network_list statusMin:500 limit:5
< [{id:abc, statusCode:503, host:"api.x.com"}, ...]
> network_get id:abc
```
