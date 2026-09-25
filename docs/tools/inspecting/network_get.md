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

Live mode: calls `getHttpProfileRequest` on the VM service, on the isolate you pass as `isolateId`, else the isolate recorded for this id in the DB, else every HTTP-profiling isolate in turn. If the live fetch fails but the request is already persisted, you get the DB copy instead: `source:"live-db-fallback"`, `degraded:true`, and a leading warning with the live error.

History mode (a `session_open` view, or a `sessionId` that is not attached): reads from `http_requests` + `http_bodies`. When a body is missing, a `warnings` entry says why: "not persisted yet (writer may still be backfilling)" while the session can still capture, or "was never captured before the session ended/was interrupted" once it cannot. Lifecycle events are not stored, so `includeEvents` has no effect here, and `isComplete` / `isResponseComplete` are not returned.

Bodies decode as UTF-8 for text content types (`application/json`, `application/xml`, `application/x-www-form-urlencoded`, `application/javascript`, `application/graphql`, the `+json` API types, `text/*`), base64 otherwise. Truncated payloads carry `{truncated:true, totalSize, truncationMode}` in the body sub-object AND a top-level `warnings[]` entry pointing at `network_body`.

**Semantic truncation (0.7.0+).** For JSON and HTML bodies, truncation now preserves STRUCTURE instead of slicing at the byte cap:

- **JSON**: arrays past 5 elements collapse to first 5 + a `{"_truncated":"42 more, 5 of 47 shown"}` marker. String leaves > 200 chars clip with `…(<n> chars)` suffix. Object keys are all preserved (the shape is what the agent needs). The output is pretty-printed with 2-space indent for readability.
- **HTML**: `<script>` + `<style>` contents stripped, comments removed, whitespace collapsed.

The `truncationMode` field tells you which path ran: `"semantic"` (JSON/HTML structural), `"byte"` (byte-cap fallback for everything else: other text types, binary, JSON that does not parse, or bodies over 256 KB), or omitted when nothing was truncated. A typical "list of 100 users" response now lands at ~1 KB with all keys + 5 sample rows visible, instead of a half-mangled 4 KB byte slice. The agent reads the same information AND can parse it. If the structural preview still exceeds `bodyTruncateBytes`, it is cut at that many characters and stays `truncated:true`.

For byte-exact paging of the full untruncated payload, use `network_body` (which always returns byte-exact content regardless of mode). After semantic truncation the `nextSteps` point `network_body` at `offset:0`, because offsets into the preview do not map to the raw body.

Header values longer than `headerTruncateBytes` become `{value, truncated, totalLength}` objects so a 4 KB JWT doesn't drown the payload. At most 64 headers are shown per side; the rest are counted in `_omitted`.

**Redaction (default on).** With `redact` unset or `true`, auth-like headers (`authorization`, `cookie`, `proxy-authorization`, `x-api-key`, `x-auth-token`, plus names added via `redacted_headers`) show as the plain string `"<redacted>"`. Pass `redact:false` to see real values when debugging auth.

**Body decryption.** When `session_configure bodyDecryption:{...}` is on, each body sub-object is decrypted before decoding and carries `decrypted:true` (its `mimeType` becomes `application/json` when the plaintext starts with `{` or `[`, else `text/plain; charset=utf-8`). A body that does not fit the scheme is returned as captured with `decrypted:false` and `decryptionFailed:"<reason>"`; this is never an error. `totalSize` then counts plaintext bytes.

## Args

- `id` (string, required): request id from `network_list` or `network_search`.
- `sessionId` (int, optional): session to read. Omit to auto-resolve (the sole attached session, or the one you opened). A session that is not attached is read from history.
- `appNameContains` (string, optional): pick the attached session by app-name substring instead of `sessionId`.
- `isolateId` (string, optional, live only): try only this isolate (id from `network_status`).
- `includeBodies` (bool, default true): set false to skip both bodies entirely.
- `bodyTruncateBytes` (int, default 4096, hard cap 262144): max bytes per body. Pass 0 (or a negative number) to use the hard cap.
- `headerTruncateBytes` (int, default 256, hard cap 4096): max chars per header value. 0 or negative means the default.
- `includeEvents` (bool, default false, live only): include the request lifecycle events array (first 50 events, then `{"_omitted": N}`). Opt-in to save tokens.
- `redact` (bool, default true): mask auth-like headers as `"<redacted>"`. Pass false to debug auth.

## Returns

```json
{
  "source": "live",
  "scope": {"sessionId": 1, "appName": "my_app", "isLive": true},
  "sessionId": 1,
  "isolateId": "isolates/1234",
  "summary": "GET https://api.example.com/feed/vendors?page=1&limit=20 → 200 OK · 372ms (application/json)",
  "id": "-748091783736179394",
  "method": "GET",
  "uri": "https://...",
  "startTimeMs": 1779414305402,
  "endTimeMs": 1779414305775,
  "durationMs": 372,
  "isComplete": true,
  "isResponseComplete": true,
  "request": {
    "headers": {"Accept":"application/json", "Authorization":"<redacted>"},
    "contentLength": 0,
    "bodyStatus": "empty"
  },
  "response": {
    "statusCode": 200,
    "reasonPhrase": "OK",
    "headers": {"content-type": "application/json; charset=utf-8"},
    "sizeKnown": false,
    "bodyStatus": "stored",
    "body": {"encoding":"utf8","size":1180,"totalSize":18432,"truncated":true,
             "truncationMode":"semantic","mimeType":"application/json; charset=utf-8","value":"..."}
  },
  "warnings": [
    "Response body truncated — totalSize 18432 bytes. Call network_body which:response for the full payload."
  ],
  "nextSteps": [
    "network_body_outline id:\"-748091...\" (structure of the full body: keys/types/sizes, no values)",
    "network_body id:\"-748091...\" which:response offset:0 length:16384 (the raw body, totalSize 18432)",
    "network_replay id:\"-748091...\" — runnable curl reproduction (auth headers redacted)",
    "network_diff idA:\"-748091...\" idB:\"<other id>\" — compare with another captured request"
  ]
}
```

Null-valued fields are omitted. The `warnings` array only appears when something is degraded (truncation, in-flight, error, missing body, DB fallback, or a scope note such as reading history while live sessions are attached). `nextSteps` is filtered against active capabilities: with a truncated response body they lead with `network_body_outline` and `network_body which:response` (`offset:0` after semantic truncation, `offset:4096` after byte truncation); with only a truncated request body, a `network_body which:request` step; then always `network_replay` and `network_diff`. The step wording above is shortened.

Other fields that appear when present: `request.error` / `response.error` (in place of headers when that side failed), `request.cookies`, `response.redirects` (the redirect chain the request followed), `response.compressionState` (live only), `events` (live only, with `includeEvents:true`), and `degraded:true` with `source:"live-db-fallback"`. `source` is `live`, `history`, or `live-db-fallback`.

**`contentLength` vs `sizeKnown` (#62).** A `contentLength` is a real byte count (`0` = the message genuinely had no body). When the size was unknown ahead of the body (chunked transfer-encoding, or no `Content-Length` header) you get `sizeKnown: false` *instead of* a misleading `contentLength: -1` — the true size is only known once the body is read. Pair it with `bodyStatus` to tell a streamed-but-present body (`sizeKnown:false` + `bodyStatus:"stored"`) from a genuinely empty one (`contentLength:0` + `bodyStatus:"empty"`).

**`bodyStatus` (#59).** Every request/response carries one of: `stored` (bytes present), `empty` (server sent no body), `pending` (the async body backfill has not run yet — retry in ~2s or read live), or `unavailable` (the body was lost before capture; `fetchAttempts` + `reason` explain). This is what stops "no body" from being ambiguous.

Errors (each carries `nextSteps`):

- `bad_argument`: `id` missing.
- `not_found`: the id is in neither the live VM profile nor the DB (live), or not in the viewed session (history).
- `unresponsive_vm`: no HTTP-profiling isolates are known, or the live fetch failed for a reason other than an unknown id and the request is not persisted either. The reply includes `id` and `triedIsolates`.
- `internal`: the history read threw.
- Scope failures (not attached and nothing opened, ambiguous `appNameContains`, several sessions and no default) return an `error` with `nextSteps` (and `attached` / `matches` where relevant) but no `errorKind`.

```json
// Missing id
{"error":"Missing required arg `id`.",
 "errorKind":"bad_argument",
 "nextSteps":["network_list — list captured requests and copy an id",
              "network_search query:\"...\" — find a request by body/url content"]}

// History id not found
{"error":"Request `xyz` not found in session 14.",
 "errorKind":"not_found",
 "sessionId":14,
 "nextSteps":["network_list — list valid request ids in this session",
              "session_list — confirm the session id is correct"]}
```

## Pairs well with

- `network_list` → pick an id → `network_get`.
- `network_body` — when bodies are truncated.
- `network_body_outline` / `network_body_query`: see the shape of a large body, or pull one field or regex match out of it.
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
