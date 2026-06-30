---
tool: network_list
description: Paginated HTTP request summaries with filters, cursors, capability-aware nextSteps, and a one-line summary. Bodies NOT included.
when_to_use: To find requests by metadata (host, method, status, time range) and get ids to pass to other tools.
---

## DO NOT USE THIS TOOL WHEN

- You need full request data — use `network_get` after picking an id from this list.
- You're looking for a string inside bodies — use `network_search`. This tool only sees metadata.
- You already have a specific request id — call `network_get` directly.
- You want bodies in the result — they're never returned by list. Sizes only.
- You're polling rapidly without using the cursor — pass `since:<prior nextCursor>` to get only new activity. Cursor is incremental by default already.
- You expect this to also drain alerts — it doesn't. Call `alerts_drain` separately (the success `nextSteps` points there when alerts capability is on).

## Use this when

- The user asks "what requests has the app made?" — start here, page down with `since:nextCursor`.
- Looking for failures: `statusMin:400`.
- Looking for traffic to a specific service: `hostContains:"api.example"`.
- Reviewing a past session: `session_open id:<n>` first, then `network_list` (it auto-switches to history mode).
- Periodic polling — leave `since` unset and the cursor advances on its own.

## How it works

Live mode (no `session_open`): calls `getHttpProfile` on the VM service with `updatedSince` = `since` arg ?? session's stored cursor. Sorts newest-first, applies filters in-process, returns up to `limit` summaries. Updates the session cursor so the next call without `since` is automatically incremental.

History mode (after `session_open`): runs an indexed SQL query against `http_requests` for the viewed session.

In both modes, the response includes:
- `summary` — one-line synthesis the agent can echo to the user.
- `count` (returned) + `totalScanned` (live only, pre-filter count).
- `nextCursor` — pass back as `since` for the next page.
- `warnings: []` — only present when something is off (empty profile, all-filtered, filter-dropout >5×).
- `nextSteps` — 1–3 concrete actions, filtered against active capabilities.
- `requests[]` — newest-first summaries.

## Args

- `since` (int, optional) — microsecond cursor. Omit for incremental behavior in live mode. Pass `0` to fetch everything.
- `method` (string[], optional) — `["GET","POST"]`.
- `hostContains` (string, optional) — case-insensitive substring on host.
- `statusMin` / `statusMax` (int, optional) — inclusive bounds.
- `limit` (int, default 50, hard cap 200).

## Returns

```json
{
  "source": "live",
  "sessionId": 14,
  "summary": "5 request(s) from session 14 (live, newest-first) — incremental since last call.",
  "count": 5,
  "totalScanned": 5,
  "nextCursor": 1700000000000000,
  "nextSteps": [
    "network_get id:\"abc\" — full headers + body for the top match",
    "network_search query:\"...\" — find requests by body/url content",
    "alerts_drain — surface anything the detector flagged"
  ],
  "requests": [
    {"id":"abc","method":"POST","uri":"...","host":"...","path":"...",
     "startTimeMs":...,"endTimeMs":...,"durationMs":124,"isComplete":true,
     "statusCode":200,"responseContentLength":4521,
     "responseContentType":"application/json"}
  ]
}
```

Null-valued fields are omitted per-request to keep payloads tight.

`requestContentLength` / `responseContentLength` are real byte counts (`0` = no body). A chunked / unknown-length message is reported as `requestSizeKnown: false` / `responseSizeKnown: false` instead of a misleading `-1` (#62); `network_get` on that id resolves the true size once the body is read.

Error shapes:

```json
// Not attached and no history opened
{"error":"Not attached and no session opened — nothing to list.",
 "nextSteps":["network_status — see DTD apps and pick what to attach to",
              "network_attach — connect to a live app",
              "session_open id:<n> — read a past session from the DB instead"]}

// VM service call failed (e.g. mid-detach)
{"error":"getHttpProfile failed: ...",
 "nextSteps":["network_status — check VM service connection and zombie state",
              "network_detach then network_attach — full reset"]}
```

## Pairs well with

- `network_get` — drill into a specific id.
- `network_body` — when `network_get` reports truncated bodies.
- `network_search` — content match instead of metadata.
- `alerts_drain` — see what the detector flagged from this batch.
- `network_query` — when filtering needs are more structural than these args allow.

## Example

```
> network_list statusMin:500 limit:5
< {summary:"0 requests scanned, 0 matched filters.",
   warnings:["Capture profile is empty — drive the app to generate traffic, then re-call."],
   nextSteps:["Drive the app...", "Drop filters and pass since:0 to re-scan from the start"]}
> # user drives the app
> network_list statusMin:500 limit:5
< {summary:"3 request(s) from session 14 (live)...",
   requests:[{id:"x1", statusCode:503, host:"api.example.com"}, ...],
   nextCursor:1700000123456789,
   nextSteps:["network_get id:\"x1\" ...", "network_search ...", "alerts_drain ..."]}
> network_get id:"x1"
```
