---
tool: network_list
description: Paginated HTTP request summaries with filters, cursors, capability-aware nextSteps, and a one-line summary. Bodies NOT included.
when_to_use: To find requests by metadata (host, method, status, time range) and get ids to pass to other tools.
---

## DO NOT USE THIS TOOL WHEN

- You need full request data. Use `network_get` after picking an id from this list.
- You're looking for a string inside bodies. Use `network_search`; this tool only sees metadata.
- You already have a specific request id. Call `network_get` directly.
- You want bodies in the result. They are never returned by list, only sizes.
- You want the shape of the session (which endpoints, how often, how slow). `network_summarize` gives one row per endpoint instead of one row per request.
- You expect this to drain alerts. It doesn't. When alerts are pending for the session, every reply carries a `pendingAlerts` block; call `alerts_drain` to read them.

## Use this when

- The user asks "what requests has the app made?". Start here; a live read is incremental, so the next call returns only what is new.
- Looking for failures: `statusMin:400`.
- Looking for traffic to a specific service: `hostContains:"api.example"`.
- Reviewing a past session: pass `sessionId:<n>`, or `session_open id:<n>` first, then `network_list` (it reads history).
- Periodic polling of a live session: leave `since` unset and the stored cursor advances on its own.

## How it works

The session comes from `sessionId`, else `appNameContains` (must match exactly one attached app), else the session opened with `session_open`, else the sole attached session. With several attached sessions and no scope arg, it picks the one attached from this project directory, else the most recently used one, and reports the choice in `scope.pickedBy` and the other candidates in `scope.others`.

Sticky defaults from `session_configure` (`method`, `hostContains`, `statusMin`, `statusMax`, `maxResponseTokens`) fill any of those args you omit. An arg you pass, even `null`, wins.

**Live read** (`source:"live"`): used when the session is live-attached and you pass neither `since:0` nor `before`. Calls `getHttpProfile` on every HTTP-profiling isolate (or only `isolateId`) with `updatedSince` = your `since`, else that isolate's stored cursor. Merges the isolates newest-first, applies the filters in-process and stops at `limit`. Every successful isolate fetch moves that isolate's stored cursor to the profile timestamp, so the next call without `since` returns only requests updated after it.

Nothing new is skipped: rows fetched but not returned (past `limit`, or trimmed by the token budget) are kept, and the next call without `since` returns them, merged newest-first with anything that arrived since. The reply says how many are waiting in `remaining`, in the summary, and in a `network_list` next step. Rows a filter excluded are not kept.

When the profile fetch fails for some isolates, the reply returns the rest with `partial:true`, `failedIsolates`, and a warning naming them; those isolates keep their cursor, so the next call retries them. When it fails for every isolate, the reply is the live DB fallback below.

**History read** (`source:"history"`): used for a non-live scope (after `session_open`, an ended session, or an explicit historical `sessionId`), and for a live session when you pass `since:0` (or any value <= 0) or `before`. Runs an indexed SQL query over `http_requests`, newest-first by start time. `since` keeps rows that started after it; `before` keeps rows that started before it. This is how you page OLDER: pass the reply's `nextCursor` as `before`.

**Live DB fallback** (`source:"live-db-fallback"`): when the profile fetch fails for every isolate (or the live read throws as a whole), the reply is the persisted DB snapshot for the session with two warnings saying so. If the DB read fails too, the tool errors with `errorKind:"unresponsive_vm"`.

`maxTokens` (or the sticky `maxResponseTokens`) trims `requests` newest-first to fit an estimated token budget (JSON length / 4), always keeping at least one row, and reports `budget:{maxTokens, dropped}`.

## Args

- `sessionId` (int, optional). Session to read. Omit to auto-resolve.
- `appNameContains` (string, optional). Pick the attached session by app-name substring instead of `sessionId`.
- `since` (int, optional). Microsecond cursor. Omit for the incremental live read. `0` (or negative) returns everything the session captured, served from the DB even for a live session. A positive value reads requests updated (live) or started (history) after it.
- `before` (int, optional). Microsecond start time; only requests that started before it (history path, pages older). Passing it on a live session also switches to the history path.
- `method` (string[], optional). `["GET","POST"]`, case-insensitive.
- `hostContains` (string, optional). Case-insensitive substring on host.
- `statusMin` / `statusMax` (int, optional). Inclusive bounds. A request with no status yet is excluded when either bound is set.
- `isolateId` (string, optional). Restrict to one isolate (id from `network_status`). Omit to merge all isolates.
- `limit` (int, default 50, cap 200). Values <= 0 fall back to 50.
- `maxTokens` (int, optional). Token budget for this reply; overrides the sticky `maxResponseTokens`.

## Returns

```json
{
  "source": "live",
  "scope": {"sessionId": 14, "appName": "my_app", "isLive": true},
  "sessionId": 14,
  "summary": "5 request(s) from session 14 (live, my_app), newest-first (new since your last call).",
  "count": 5,
  "totalScanned": 5,
  "nextCursor": 1700000000000000,
  "nextSteps": [
    "network_get id:\"abc\" ...",
    "network_search query:\"...\" ..."
  ],
  "requests": [
    {"id":"abc","method":"POST","uri":"...","host":"...","path":"...",
     "startTimeMs":...,"endTimeMs":...,"durationMs":124,"isComplete":true,
     "statusCode":200,"reasonPhrase":"OK","requestContentLength":312,
     "responseContentLength":4521,"responseContentType":"application/json",
     "isolateId":"isolates/123"}
  ]
}
```

Top-level fields:

- `source`: `live`, `history` or `live-db-fallback`.
- `scope`: which session was read (`sessionId`, `appName`, `isLive`, and `note` / `pickedBy` / `others` when relevant). A scope note (for example an open `session_open` view shadowing live sessions) is also copied to `warnings`.
- `count`: rows returned. `totalScanned` (live only): rows considered before filtering (this fetch plus rows kept from an earlier read).
- `nextCursor`. Live: the profile timestamp, pass it back as `since`. History: the oldest start time in the batch when the page was full (pass it as `before` to page older), else `null`. Fallback: same as history, present only when the page was full.
- `newestInBatch` (history only): newest start time in the batch, for `since` paging.
- `remaining` (live only): new rows fetched but not returned yet (past `limit` or the token budget). The next call without `since` returns them. Absent when nothing is waiting.
- `partial: true` (live only): some rows could not be read and were skipped, or some isolates failed (listed in `failedIsolates`).
- `budget`: present when a token budget applied.
- `warnings`: only when something is off (empty profile, filters excluded everything, filters dropped over 80% of scanned rows, rows skipped, isolates that failed, budget trim, scope note).
- `nextSteps`: 1 to 5 concrete calls; the `network_search` hint appears only when the search capability is on.
- `pendingAlerts`: added automatically when alerts are pending for the session.

Per-request fields (null values are omitted): `id`, `method`, `uri`, `host`, `path`, `startTimeMs`, `endTimeMs`, `durationMs`, `statusCode`, `reasonPhrase`, `requestContentLength` / `responseContentLength`, `responseContentType`, `isolateId`, `hasError`. Live rows also carry `isComplete` and, for a failed request, `error`.

`requestContentLength` / `responseContentLength` are real byte counts (`0` = no body). A chunked / unknown-length message is reported as `requestSizeKnown: false` / `responseSizeKnown: false` instead of a misleading `-1` (#62); `network_get` on that id resolves the true size once the body is read.

Empty reads say why: `No HTTP captured yet in ...` (nothing ever), `No NEW HTTP since your last call ...` (incremental read, pass `since:0`), `N request(s) scanned, 0 matched filters.` (filters), and in history `No requests in session N match the given filters/cursor.` An empty history read's next steps depend on why it is empty (a `before` / `since` bound, active filters, or a session with no capture) and suggest `session_close` only while a `session_open` view of that session is active.

Error shapes:

```json
// Nothing attached and no session opened
{"error":"Not attached and no session opened for viewing. Call network_attach to capture live, or session_open id:<N> to read from a historical session, or pass sessionId:<N> directly.",
 "errorKind":"no_session",
 "nextSteps":["network_status ...", "network_attach ...", "session_list ..."]}

// Live read failed and the DB fallback failed too
{"error":"Live read failed and the DB fallback also failed. Live: ... DB: ...",
 "errorKind":"unresponsive_vm",
 "sessionId":14,
 "nextSteps":["network_search query:\"...\" ...", "network_query sql:\"...\" ...", "network_status ..."]}

// History query failed
{"error":"history query failed: ...", "errorKind":"internal", "sessionId":14,
 "nextSteps":["Verify the session still exists via session_list",
              "session_close if the viewed session was deleted"]}
```

When the last attached app exited, the not-attached error names that session and adds `session_open id:<n>` as the first next step. `appNameContains` matching no attached session returns `errorKind:"no_session"`, and matching several returns `bad_argument`; both list the candidates. A call that runs past the per-tool deadline returns `errorKind:"timeout"`.

## Pairs well with

- `network_get`: drill into a specific id.
- `network_body`: when `network_get` reports truncated bodies.
- `network_search`: content match instead of metadata.
- `network_summarize`: one row per endpoint instead of per request.
- `alerts_drain`: see what the detector flagged.
- `session_configure`: set sticky filters or a token budget once.
- `network_query`: when filtering needs are more structural than these args allow.

## Example

```
> network_list statusMin:500 limit:5
< {source:"live", summary:"No HTTP captured yet in session 14 (live, my_app).",
   warnings:["Capture profile is empty. Drive the app to generate traffic, then re-call."],
   nextSteps:["Drive the app to generate traffic, then call network_list again", "Drop filters to widen the match"]}
> # user drives the app
> network_list statusMin:500 limit:5
< {summary:"3 request(s) from session 14 (live, my_app), newest-first (new since your last call).",
   requests:[{id:"x1", statusCode:503, host:"api.example.com"}, ...],
   nextCursor:1700000123456789,
   nextSteps:["network_get id:\"x1\" ...", "network_search ..."]}
> network_get id:"x1"
```
