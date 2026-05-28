---
tool: network_correlate
description: Find correlated HTTP requests across multiple captured sessions — the typed companion to network_query SQL for the "webhook originator + receiver" pattern.
when_to_use: When a single logical operation spans 2+ apps (mobile → webhook → backend → driver app) and you want to find the matching halves by a shared id / URL fragment / body substring.
---

## DO NOT USE THIS TOOL WHEN

- The agent only has one session in scope — `pairs` will be empty. Use `network_search` for single-session content matching instead.
- The user wants ALL requests across sessions — this is a *correlation* tool, not a global filter. It biases toward requests containing the same substring across sessions. For wide cross-session sweeps use `network_query` SQL.
- You don't know what string to look for. The pattern is REQUIRED — without it the tool can't find correlations. If the user only has a vague "what's happening across apps?", reach for `network_status` + per-session `network_list` first to spot a candidate id.
- You want header-level correlation (e.g. shared `X-Request-Id`). v1 of this tool matches URL + body only. Headers aren't indexed in FTS5. Use `network_query` for header joins.

## Use this when

- "Find the webhook flow for transaction abc-123": `network_correlate sessionIds:[14,15] pattern:"abc-123"` returns the originator (mobile session 14) + the receiver (driver session 15) paired by body substring.
- "Did sanga_driver receive the webhook sanga_mobile sent at 14:32?": `pattern:"/handlers/webhook/order" timeWindowMs:5000` returns pairs within 5 seconds of each other.
- "Which requests in session A contain an error id that also appears in session B's response?": `which:"any"` searches both URL + bodies for the pattern.

## How it works

1. Validates `sessionIds:[int]` (REQUIRED, max 8) and `pattern:string` (REQUIRED, non-empty). No auto-resolve — cross-session aggregation is intentional, so the agent must pick.
2. Runs FTS5 search (`http_search` virtual table) for each session, capped at `perSessionLimit` (default 100, hard cap 500) BEFORE pairing — bounds the work regardless of pattern noisiness.
3. Cross-joins matches between every pair of distinct sessions. When `timeWindowMs` is set, drops pairs whose start-time delta exceeds it. Pairs are sorted by smallest delta first (tightest pairs at the top).
4. Returns up to `limit` pairs (default 20, hard cap 100) plus the raw `sessions:[{matches}]` per-session lists so the agent can inspect individual matches outside the pair filter.

## Required args

- `sessionIds: [int]` — list of session ids. Get them from `network_status.attached[].sessionId` or `session_list`. Hard cap 8.
- `pattern: string` — substring to search for. Phrase-quoted in FTS5 so hyphens / colons / special chars work naturally.

## Optional args

- `which: "url" | "request" | "response" | "any"` — default `"any"`. Use `"response"` for error-id hunting, `"request"` for shared body fields, `"url"` for path fragment matching.
- `timeWindowMs: int` — max milliseconds between paired requests' start times. Omit for no window. Try 1000–5000ms for tight request → webhook pairs.
- `limit: int` — max pairs returned (default 20, hard cap 100). Pairs are sorted tightest-first.
- `perSessionLimit: int` — max raw matches per session before pairing (default 100, hard cap 500). Bumps memory + the eventual cross-product size.

## Returns

```json
{
  "scope": {"sessionIds": [14, 15]},
  "pattern": "txn-abc-123",
  "which": "any",
  "timeWindowMs": 5000,
  "summary": "Found 6 matched request(s) across sessions 14, 15, 3 cross-session pair(s) within 5000ms.",
  "totalMatches": 6,
  "matchesPerSession": {"14": 3, "15": 3},
  "sessions": [
    {
      "sessionId": 14,
      "appName": "sanga_mobile",
      "matches": [
        {"sessionId": 14, "appName": "sanga_mobile",
         "id": "req-1234", "isolateId": "isolates/1",
         "method": "POST", "url": ".../webhook/order",
         "statusCode": 200, "startTimeMs": 1700000000000,
         "snippet": "...«txn-abc-123»..."}
      ]
    },
    {"sessionId": 15, "appName": "sanga_driver", "matches": [...]}
  ],
  "pairs": [
    {
      "match": "txn-abc-123",
      "spanMs": 412,
      "requests": [
        {"sessionId": 14, "appName": "sanga_mobile", "id": "req-1", ...},
        {"sessionId": 15, "appName": "sanga_driver", "id": "req-2", ...}
      ]
    }
  ],
  "warnings": ["..."],
  "nextSteps": [
    "network_get sessionId:14 id:\"req-1\" — full detail on the originator",
    "network_get sessionId:15 id:\"req-2\" — full detail on the receiver"
  ]
}
```

## Errors

| Cause | Response |
|---|---|
| `sessionIds` missing / not a list / empty | `error: 'Missing or invalid sessionIds…'` |
| `sessionIds` contains non-int | `error: 'sessionIds must contain only integers…'` |
| More than 8 sessionIds | `error: 'Too many sessionIds…'` |
| `pattern` missing / empty | `error: 'Missing or empty pattern…'` |
| `which` not in {url, request, response, any} | `error: 'which must be one of…'` |
| `timeWindowMs` negative | `error: 'timeWindowMs must be >= 0'` |

Errors carry the offending args in the extra block and `nextSteps` with concrete recoveries.

## Caps

| Limit | Default | Hard max |
|---|---|---|
| `sessionIds` length | required | **8** |
| `limit` (pairs returned) | 20 | **100** |
| `perSessionLimit` (raw matches per session) | 100 | **500** |
