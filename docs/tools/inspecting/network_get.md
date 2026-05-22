---
tool: network_get
description: Full headers + decoded bodies for ONE captured HTTP request, with summary, warnings, and capability-aware nextSteps.
when_to_use: After picking an id from network_list or network_search, when you want the actual headers and body content.
---

## DO NOT USE THIS TOOL WHEN

- You don't have an id yet — use `network_list` (metadata) or `network_search` (content) first.
- You only need metadata (host/method/status) — `network_list` already returned that.
- The body is huge and you only want a slice — call `network_body` with `offset/length` directly. `network_get` is the one-shot detail view.
- You want to compare two requests — `network_diff` handles bodies + headers in one call.
- You're scripting bulk export — use `session_export` to HAR.
- You want lifecycle events — they're off by default. Pass `includeEvents:true` only when you actually need wall-clock timing milestones; they add bulk and are rarely useful.

## Use this when

- The user wants to see "what was sent" or "what came back" for a specific request.
- You need to inspect specific headers (Authorization shape, retry-after, content-type, CORS).
- You want a quick look at the body that fits in the truncation budget (default 4 KB per side).
- After `network_list` returns a hit and you want the full record.

## How it works

Live mode: calls `getHttpProfileRequest` on the VM service.

History mode: reads from `http_requests` + `http_bodies` for the viewed session. If bodies aren't persisted yet (writer hasn't backfilled — happens within ~2s of request completion), the response includes a `warnings` entry saying so.

Bodies decode as UTF-8 for json/text/xml/form content types, base64 otherwise. Truncated payloads carry `{truncated:true, totalSize}` in the body sub-object AND a top-level `warnings[]` entry pointing at `network_body`.

Header values longer than `headerTruncateBytes` become `{value, truncated, totalLength}` objects so a 4 KB JWT doesn't drown the payload.

## Args

- `id` (string, required) — request id from `network_list` or `network_search`.
- `includeBodies` (bool, default true) — set false to skip both bodies entirely.
- `bodyTruncateBytes` (int, default 4096, hard cap 262144) — max bytes per body. Pass 0 to use the hard cap.
- `headerTruncateBytes` (int, default 256, hard cap 4096) — max chars per header value.
- `includeEvents` (bool, default false) — include the request lifecycle events array. Opt-in to save tokens.

## Returns

```json
{
  "source": "live",
  "sessionId": 1,
  "summary": "GET https://nexus.sangaeats.com/feed/vendors?page=1&limit=20 → 200 OK · 372ms · -1-byte response (application/json)",
  "id": "-748091783736179394",
  "method": "GET",
  "uri": "https://...",
  "startTimeMs": 1779414305402,
  "endTimeMs": 1779414305775,
  "durationMs": 372,
  "isComplete": true,
  "isResponseComplete": true,
  "request": {
    "headers": {"Accept":"application/json", "Authorization":"Bearer <very long token>"},
    "contentLength": 0
  },
  "response": {
    "statusCode": 200,
    "reasonPhrase": "OK",
    "headers": {"content-type": "application/json; charset=utf-8"},
    "contentLength": -1,
    "body": {"encoding":"utf8","size":4096,"totalSize":18432,"truncated":true,
             "mimeType":"application/json","value":"..."}
  },
  "warnings": [
    "Response body truncated — totalSize 18432 bytes. Call network_body which:response for the full payload."
  ],
  "nextSteps": [
    "network_body id:\"-748091...\" which:response offset:4096 length:16384 — page beyond the cap (totalSize 18432)",
    "network_replay id:\"-748091...\" — runnable curl reproduction (auth headers redacted)",
    "network_diff idA:\"-748091...\" idB:\"<other id>\" — compare with another captured request"
  ]
}
```

Null-valued fields are omitted. The `warnings` array only appears when something is degraded (truncation, in-flight, error). `nextSteps` is filtered against active capabilities.

Errors:

```json
// Missing id
{"error":"Missing required arg `id`.",
 "nextSteps":["network_list — list captured requests and copy an id",
              "network_search query:\"...\" — find a request by body/url content"]}

// Not attached + no history
{"error":"Not attached and no session opened — cannot fetch a request.",
 "nextSteps":["network_status — see DTD apps",
              "network_attach — connect to a live app",
              "session_open id:<n> — view a past session and try this id there"]}

// History id not found
{"error":"Request `xyz` not found in session 14.",
 "sessionId":14,
 "nextSteps":["network_list — list valid request ids in this session",
              "session_list — confirm the session id is correct"]}
```

## Pairs well with

- `network_list` → pick an id → `network_get`.
- `network_body` — when bodies are truncated.
- `network_replay` — emit curl for the same request.
- `network_diff` — compare against another id.

## Example

```
> network_list statusMin:500 limit:1
< {requests:[{id:"x1", statusCode:503}]}
> network_get id:"x1"
< {summary:"POST /v1/login → 503 Internal Server Error · 180ms · ...",
   request:{headers:{...}, body:{value:"{...}"}},
   response:{statusCode:503, body:{value:"{\"error\":\"...\"}"}},
   warnings:["Response body truncated — ..."],
   nextSteps:["network_body ...", "network_replay ...", "network_diff ..."]}
```
