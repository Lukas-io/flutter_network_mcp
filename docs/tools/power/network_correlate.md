---
tool: network_correlate
description: Find correlated HTTP requests across multiple captured sessions — the typed companion to network_query SQL for the "webhook originator + receiver" pattern.
when_to_use: When a single logical operation spans 2+ apps (mobile → webhook → backend → driver app) and you want to find the matching halves by a shared id / URL fragment / body substring.
---

## DO NOT USE THIS TOOL WHEN

- The agent only has one session in scope — `pairs` will be empty. Use `network_search` for single-session content matching instead.
- The user wants ALL requests across sessions — this is a *correlation* tool, not a global filter. It biases toward requests containing the same substring across sessions. For wide cross-session sweeps use `network_query` SQL.
- You don't know what string to look for. The pattern is REQUIRED — without it the tool can't find correlations. If the user only has a vague "what's happening across apps?", reach for `network_status` + per-session `network_list` first to spot a candidate id.
- You want header-level correlation (e.g. shared `X-Request-Id`). This tool matches URL + body only; headers aren't in the search index. Use `network_query` for header joins.
- You want operator or regex matching. The pattern is always one FTS5 phrase.

## Use this when

- "Find the webhook flow for transaction abc-123": `network_correlate sessionIds:[14,15] pattern:"abc-123"` returns the originator (mobile session 14) + the receiver (driver session 15) paired by body substring.
- "Did sanga_driver receive the webhook sanga_mobile sent at 14:32?": `pattern:"/handlers/webhook/order" timeWindowMs:5000` returns pairs within 5 seconds of each other.
- "Which requests in session A contain an error id that also appears in session B's response?": `which:"any"` searches both URL + bodies for the pattern.

## How it works

1. Validates `sessionIds:[int]` (REQUIRED, max 8 after dropping duplicates) and `pattern:string` (REQUIRED, not blank). No auto-resolve: cross-session aggregation is intentional, so the agent must pick. Session ids are not checked for existence; an unknown id just yields no matches.
2. Runs a phrase search per session, capped at `perSessionLimit` (default 100, hard cap 500) BEFORE pairing, so the work stays bounded however noisy the pattern is. Matches are taken oldest-first by start time, so the cap keeps each session's earliest matches. Without body decryption this is the capture DB's FTS5 table (`http_search`), which holds URLs from first sight and bodies after the ~2s backfill.
3. Cross-joins matches between every pair of distinct sessions (both sides only need to contain the pattern, in any column `which` allows). Matches without a start time are left out of pairing. When `timeWindowMs` is set, drops pairs whose start-time delta exceeds it. Pairs are sorted by smallest delta first (tightest pairs at the top).
4. Returns up to `limit` pairs (default 20, hard cap 100) plus a compact per-session preview in `sessions[]` (the first 10 matches of each session, without snippets) so the agent can see matches outside the pair filter.

With body decryption on (`session_configure bodyDecryption:{...}`), step 2 searches the same in-memory plaintext index `network_search` uses instead of the capture DB. Each call first brings every named session's part of the index up to date: on first use it reads that session's stored requests and decrypts their bodies; later calls add new requests and re-read ones whose bodies were not final. Bodies that do not decrypt are indexed as-is when the stored content type is textual. Nothing decrypted is written to the capture DB; the index is dropped when the scheme is changed or turned off, or on `session_configure clear:true`, and dies with the process. The reply has the same shape either way (no field marks plaintext matches), but snippets in `pairs` can show decrypted text.

## Required args

- `sessionIds: [int]` — list of session ids. Get them from `network_status.attached[].sessionId` or `session_list`. Hard cap 8.
- `pattern: string`: text to search for. Phrase-quoted in FTS5 so hyphens / colons / special chars work naturally. FTS5 matches whole tokens, so a fragment of a token (`abc-12` for `abc-123`) does not match.

## Optional args

- `which: "url" | "request" | "response" | "any"` — default `"any"`. Use `"response"` for error-id hunting, `"request"` for shared body fields, `"url"` for path fragment matching.
- `timeWindowMs: int`: max milliseconds between paired requests' start times (`0` keeps only identical start times). Omit for no window. Try 1000 to 5000 ms for tight request to webhook pairs.
- `limit: int`: max pairs returned (default 20, hard cap 100; values <= 0 fall back to 20). Pairs are sorted tightest-first.
- `perSessionLimit: int`: max raw matches per session before pairing (default 100, hard cap 500; values <= 0 fall back to 100). Raising it grows memory and the cross-product size.

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
      "matchesTotal": 3,
      "matchesShown": 3,
      "matches": [
        {"id": "req-1234", "method": "POST", "url": ".../webhook/order",
         "statusCode": 200, "startTimeMs": 1700000000000}
      ]
    },
    {"sessionId": 15, "appName": "sanga_driver", "matchesTotal": 3, "matchesShown": 3, "matches": [...]}
  ],
  "pairs": [
    {
      "match": "txn-abc-123",
      "spanMs": 412,
      "requests": [
        {"sessionId": 14, "appName": "sanga_mobile", "id": "req-1",
         "isolateId": "isolates/1", "method": "POST", "url": "...",
         "statusCode": 200, "startTimeMs": 1700000000000,
         "snippet": "...«txn-abc-123»..."},
        {"sessionId": 15, "appName": "sanga_driver", "id": "req-2", ...}
      ]
    }
  ],
  "warnings": ["..."],
  "nextSteps": [
    "network_get sessionId:14 id:\"req-1\" ... (412ms before its pair)",
    "network_get sessionId:15 id:\"req-2\" ..."
  ]
}
```

- `appName` appears only for sessions that are attached right now; historical sessions have none.
- `sessions[].matches` is a preview: at most 10 per session, without snippets or isolate ids. `matchesTotal` is the real count. Full match rows (with `snippet`) are only inside `pairs`.
- In each pair, `requests[0]` comes from the session listed earlier in `sessionIds` and `requests[1]` from the later one; the order is not by time. `spanMs` is the absolute start-time difference.
- `nextSteps` label `requests[0]` of the tightest pair as the originator and `requests[1]` as the receiver, following that list order. Check `startTimeMs` to see which one actually came first. A third step suggests a smaller `timeWindowMs` when more than one pair is returned. With matches but no pairs, the step suggests raising or omitting `timeWindowMs`; with no matches, a shorter pattern and `network_search`.
- `warnings` cover: no matches at all, a session that hit `perSessionLimit`, a session with more than 10 matches (preview only), more candidate pairs than `limit`, and a single `sessionIds` entry (`pairs` will be empty).

## Errors

| Cause | `errorKind` | Message starts with |
|---|---|---|
| `sessionIds` missing / not a list / empty | `bad_argument` | ``Missing or invalid `sessionIds` `` |
| `sessionIds` contains non-int | `bad_argument` | `sessionIds must contain only integers` |
| More than 8 distinct sessionIds | `bad_argument` | `Too many sessionIds` (adds `sessionIdsRequested` and `cap`) |
| `pattern` missing / blank | `bad_argument` | ``Missing or empty `pattern` `` |
| `which` not in {url, request, response, any} | `bad_argument` | `` `which` must be one of `` |
| `timeWindowMs` negative | `bad_argument` | `` `timeWindowMs` must be >= 0 `` |
| The search itself threw | `bad_query` | `network_correlate failed:` (adds `sessionIds`, `pattern`) |

Every error carries `nextSteps` with concrete recoveries.

## Caps

| Limit | Default | Hard max |
|---|---|---|
| `sessionIds` length | required | **8** |
| `limit` (pairs returned) | 20 | **100** |
| `perSessionLimit` (raw matches per session) | 100 | **500** |

## Pairs well with

- `network_status` / `session_list`: get the session ids to pass.
- `network_get sessionId:<n> id:"<id>"`: full detail on each half of a pair.
- `network_search`: the same phrase search inside one session.
- `network_query`: header joins or wider cross-session SQL.

## Example

```
> network_correlate sessionIds:[14,15] pattern:"txn-abc-123" timeWindowMs:5000
< {summary:"Found 6 matched request(s) across sessions 14, 15, 3 cross-session pair(s) within 5000ms.",
   pairs:[{match:"txn-abc-123", spanMs:412, requests:[{sessionId:14, id:"req-1", ...}, {sessionId:15, id:"req-2", ...}]}, ...]}
> network_get sessionId:15 id:"req-2"
```
