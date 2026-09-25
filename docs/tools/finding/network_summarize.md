---
tool: network_summarize
description: One digest row per endpoint over a time window — count, status distribution, p50/p95 latency, error rate. Path templates collapse dynamic ids (`/api/users/42` and `/api/users/91` group as `GET api.example.com/api/users/N`).
when_to_use: After `network_status`, when you want the SHAPE of the captured session in 500 bytes instead of paging through `network_list`. Doubles as the "what's wrong with my API" first call.
---

## DO NOT USE THIS TOOL WHEN

- You need a specific captured request — use `network_get` (with the id) or `network_list` (to find the id).
- You need request body content — `network_summarize` returns aggregate metadata only, no bodies.
- The session has fewer than ~10 captured requests — at that volume, `network_list` is just as cheap and shows individual rows.
- You're chasing an alert — `alerts_drain` is the entry point for issues the server has already flagged.

## Use this when

- "What endpoints is the app hitting?" — one row per `(method, host, pathTemplate)`.
- "What's slow / what's failing?" — sort by p95 or filter the response by `errorRate > 0`.
- "Is there a hot endpoint?" — sorted by count desc, the busiest is first.
- "Did anything change in the last 5 minutes?": call with `sinceMs:300000` to scope to a window.
- For a ranked "what is broken or slow" headline instead of the full table, `network_report` builds on the same digest.

## How it works

Resolves the session like the other read tools (`sessionId`, else `appNameContains`, else the `session_open` view, else the sole or default attached session). Reads from the captures DB, for live and historical sessions alike; a live request shows up once the capture writer has persisted it (~2s tick). Pulls the newest 10 000 rows (by start time) that started inside the window and match `hostContains`, then aggregates in process:

1. Each row is bucketed by `(method.upper, host, pathTemplate(path))`.
2. `pathTemplate` collapses dynamic id segments: pure-integer → `N`, 8+ hex chars → `H`, full 8-4-4-4-12 UUID → `UUID`. Mixed-content segments (`abc-123`) stay verbatim. Query strings + fragments are stripped.
3. Per bucket: count, status code histogram (with a synthetic `error` key for rows with no status code: transport errors, and requests still in flight), p50/p95 latency in ms from the rows that have a duration (`null` when none do), error rate as `(status >= 400 + no status) / count`, rounded to 4 decimals.
4. Buckets with fewer than `minCount` requests are dropped. The rest are sorted by count desc and trimmed to `limit` (default 50, hard cap 200).

If the raw-row cap is hit, the response includes `rawRowsCapHit: true` (and the summary says so); narrow `hostContains` or shorten `sinceMs`.

## Args

- `sessionId` (int, optional). Defaults to the auto-resolved (live or viewed) session.
- `appNameContains` (string, optional). Pick the attached session by app-name substring instead of `sessionId`.
- `sinceMs` (int, optional). Relative time window, measured back from now against request start times. Defaults to 3600000 (1 h) when the session is live-attached and its app is running, else to `0`. `0` (or negative) means the entire session.
- `hostContains` (string, optional). Case-insensitive host filter.
- `limit` (int, default 50, hard cap 200). Max endpoint rows returned; values <= 0 fall back to 50.
- `minCount` (int, default 1). Drop buckets with fewer than this many requests.

## Returns

```jsonc
{
  "scope": {...},
  "sessionId": 14,
  "summary": "3 distinct endpoint(s) over 1h, 247 total request(s) considered.",
  "window": "1h",
  "rawRowsConsidered": 247,
  "count": 3,
  "endpoints": [
    {
      "endpoint": "GET api.example.com/api/users/N",
      "method": "GET",
      "host": "api.example.com",
      "pathTemplate": "/api/users/N",
      "count": 198,
      "statusDist": {"200": 187, "404": 10, "500": 1},
      "p50LatencyMs": 145,
      "p95LatencyMs": 820,
      "errorRate": 0.0556
    },
    {
      "endpoint": "POST api.example.com/api/login",
      "method": "POST",
      "host": "api.example.com",
      "pathTemplate": "/api/login",
      "count": 3,
      "statusDist": {"200": 3},
      "p50LatencyMs": 210,
      "p95LatencyMs": 290,
      "errorRate": 0.0
    }
  ],
  "nextSteps": [
    "network_list hostContains:\"api.example.com\" — drill into the busiest endpoint (GET api.example.com/api/users/N, 198 request(s))",
    "alerts_drain — at least one endpoint has a non-zero error rate; check for queued alerts"
  ]
}
```

`window` is the window formatted as `<n>ms` under a minute, `<n>m` under an hour, else `<n>h` (rounded), or `"entire session"`. `count` is the number of endpoint rows returned. When the result is truncated by `limit`, `truncatedAt:<n>` appears at top level and a `nextSteps` line suggests raising `limit` or narrowing `hostContains`. The `alerts_drain` next step appears only when a returned endpoint has a non-zero error rate. When alerts are pending for the session, a `pendingAlerts` block is added automatically.

When nothing matches, the summary reads `No HTTP requests captured over <window>.` followed by a note that only dart:io traffic is captured, and the single next step depends on the session state: drive the app and re-run (live), or a statement that the capture is complete (ended, interrupted, or the app exited).

Errors: `errorKind:"internal"` with `network_summarize query failed: ...` when the DB read fails. Scope failures (nothing attached and no session opened, `appNameContains` matching none or several) return an error with `nextSteps` and no `errorKind`.

## Pairs well with

- `network_status` — call FIRST; if it shows captured requests, follow with `network_summarize`.
- `network_list hostContains:"..."` — drill into the busiest endpoint after summarize identifies it.
- `alerts_drain` — when `errorRate > 0` on any endpoint.
- `network_query` — when the typed summary isn't enough; raw SQL over the same data.

## Example flow

```
> network_status
< {alerts: {pendingTotal: 2}, sessionCount: 1, attached: [{sessionId: 14, ...}]}
> network_summarize sinceMs:600000
< {count: 5, endpoints: [
     {endpoint:"GET .../api/users/N", count: 89, p95LatencyMs: 1240, errorRate: 0.12},
     ...
  ]}
> # the agent: "the users endpoint has a 12% error rate and p95 is 1.2s — let me drill in"
> network_list hostContains:"api.example.com" statusMin:400
< [...]
```
