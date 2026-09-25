---
tool: network_search
description: Full-text search across captured HTTP urls + request/response bodies (SQLite FTS5), with BM25 ranking.
when_to_use: When the user describes a symptom in plain language ("auth failed", "rate_limit") and you need to find the requests that contain that string.
---

## DO NOT USE THIS TOOL WHEN

- The request just completed and you need a BODY match. URLs are searchable from first sight, but bodies only after the capture writer backfills them (~2s tick). Retry shortly.
- You only need to filter by host/method/status. `network_list` does that without a full-text scan.
- You already have a specific id. Use `network_get`.
- The match is structural (header present, status range, time window). Use `network_query` with SQL; headers are not in the search index.
- You want operator semantics (AND, OR, NEAR, prefix `*`). The query is always wrapped as one FTS5 phrase, so operators are matched as literal words. Compose several calls, or write a `MATCH` query over `http_search` with `network_query` (that reads the capture DB only, so it never sees decrypted plaintext).
- You want a regex. There is no regex mode here; `network_body_query grep:` runs a regex inside one body.
- The term spans several captured sessions (for example an originator app and a receiver app). Use `network_correlate`.

## Use this when

- "Find the request whose response had 'invalid_token'". Exactly this.
- Searching history for a token you remember by content.
- The user pasted an error message: "where did this come from?"
- You remember part of a URL path or a percent-encoded query value (the index holds each URL raw and percent-decoded).

## How it works

Resolves the session like the other read tools (`sessionId`, else `appNameContains`, else the `session_open` view, else the sole or default attached session). Wraps the query as an FTS5 phrase (`"..."`, inner quotes doubled) so `-`, `:`, `(` and similar don't trip the parser. `which` limits the phrase to one column: `url`, `content_request` or `content_response`; `any` matches all three. Ranked by BM25 (lowest `rank` = best match). Snippets are 12-token windows with «highlights».

**Without body decryption** (the default), it searches the capture DB's FTS5 table `http_search` (url + content_request + content_response), joined back to `http_requests` via `http_search_map`. The capture writer indexes each URL (raw and percent-decoded) when it first sees the request, then re-indexes with body text when it backfills the bodies (~2s tick). A body is indexed only when its own content type contains json, xml, text, javascript, graphql or form-urlencoded; it is decoded as UTF-8. Other bodies (binary, images, protobuf) are never indexed.

**With body decryption on** (`session_configure bodyDecryption:{...}`), it searches an in-memory FTS5 index instead. On the first search of a session it reads every stored request of that session from the capture DB, decrypts each stored body with the configured AES-CTR scheme, and indexes the plaintext with the URL. A body that does not decrypt to UTF-8 text is indexed as-is when the request's stored content type (the response's, else the request's) is textual, else not at all. Later searches (and `network_correlate`) add requests that arrived since and re-read requests whose bodies were not final yet. The plaintext index lives only in this process's memory: nothing decrypted is written to the capture DB. It is dropped when `session_configure` sets a new scheme (even the same key again), turns decryption off (`bodyDecryption:{off:true}`), or runs `clear:true`, and it dies with the process. A session's rows are dropped when `session_delete` deletes it, when `bodies_purge` or the rolling DB cap removes any of its bodies, or when the cap removes the session; the next search rebuilds from what the capture DB still holds. In this mode the reply carries `index: "decrypted-in-memory"`; matches and snippets otherwise look the same, but snippets can show decrypted text. The first search after turning decryption on decrypts every stored body of the session, so it takes longer on a large session.

On zero matches the reply reports coverage of the index it actually searched (the capture DB's, or the in-memory decrypted one when body decryption is on): nothing indexed yet, only some of the captured requests indexed, some bodies not stored (not persisted yet, purged, or the session ended first), or everything indexed (the term is absent). It then adds `availableHosts` (up to 15 hosts, busiest first), `suggestedPaths` (up to 5 captured paths close to the query) and a warning that only dart:io traffic is captured.

## Args

- `query` (string, required). Phrase-matched; must not be blank. FTS5 matches whole tokens (case-insensitive), so a fragment of a word does not match: `tok` does not find `token`. Punctuation such as `_`, `-`, `/` splits words.
- `sessionId` (int, optional). Defaults to the auto-resolved session.
- `appNameContains` (string, optional). Pick the attached session by app-name substring instead of `sessionId`.
- `isolateId` (string, optional). Restrict to one isolate (id from `network_status`).
- `which` (string, default `"any"`). `"url"` | `"request"` | `"response"` | `"any"`.
- `limit` (int, default 20, cap 100). Values <= 0 fall back to 20.

## Returns

```json
{
  "scope": {"sessionId": 14, "appName": "my_app", "isLive": true},
  "sessionId": 14,
  "summary": "1 match(es) for \"invalid_token\" in session 14 (ranked by BM25).",
  "query": "invalid_token",
  "which": "any",
  "count": 1,
  "matches": [
    {"sessionId":14, "id":"req-1", "method":"POST",
     "url":"https://api.example.com/v1/login", "statusCode":500,
     "snippet":"{\"error\":\"«invalid_token»\",\"message\":\"auth failed\"}",
     "rank": -1.2e-06}
  ],
  "nextSteps": [
    "network_get id:\"req-1\" ..."
  ]
}
```

With two or more matches, `nextSteps` also offers `network_diff idA:<top> idB:<second>`.

Empty results use the summary `No matches for "<query>" in session N (which=<which>).` and carry `warnings` (index coverage plus the capture-boundary note), `availableHosts` and `suggestedPaths` when there is something to suggest, and `nextSteps` such as `did you mean: "/driver/deliveries" ...`, `Retry with a shorter substring or which:"any"`, and `network_list`.

Errors:

| Cause | `errorKind` |
|---|---|
| `query` missing or blank | `bad_argument` |
| `which` not url / request / response / any | `bad_argument` |
| The search itself threw (`network_search failed: ...`) | `bad_query` |
| No session could be resolved, or `appNameContains` matched none / several | none (error with `nextSteps`) |

## Pairs well with

- `network_get`: pass the matched id for full detail.
- `session_open`: search inside a specific historical session.
- `network_diff`: once you have two matching ids.
- `network_list`: when metadata filtering is more direct.
- `network_correlate`: the same search across several sessions, paired by time.
- `session_configure`: turn on body decryption for app-encrypted bodies.

## Example

```
> network_search query:"invalid_token"
< {summary:"1 match(es)...", matches:[{id:"req-1", snippet:"{...«invalid_token»..."}]}
> network_get id:"req-1"
```
