---
tool: network_query
description: Read-only SQL escape hatch against the captures DB. Single SELECT only. BLOB-safe and cell-capped.
when_to_use: When structured tools can't express the question — joins across tables, aggregations, ad-hoc analysis.
---

## DO NOT USE THIS TOOL WHEN

- A purpose-built tool exists — `network_list` for filtered summaries, `network_search` for FTS, `alerts_drain` for alerts. Reach for SQL only when those can't express the question.
- You want to mutate data — this rejects anything that isn't SELECT / WITH...SELECT.
- The user wants a quick overview — SQL output is raw; structured tools synthesize.
- You're tempted to write a 5-table join — start simpler. Cumulative raw-SQL output is heavier than structured tools.

## Use this when

- "Show me request count by host across all sessions" — a GROUP BY query.
- "Average duration of POSTs to /api/* in the last hour" — aggregation.
- Cross-table joins (e.g., http_requests + log_records by time proximity).
- Schema exploration: `SELECT name FROM sqlite_schema WHERE type='table'`.

## How it works

Trims whitespace and trailing semicolons. Rejects a statement that does not start with `SELECT` or `WITH ` (case-insensitive). Rejects any remaining `;`, even one inside a string literal. Wraps your statement in `SELECT * FROM (...) LIMIT 500` so the row cap applies regardless of your own LIMIT. BLOB cells return `{type:"blob", size:N}` to avoid dumping bytes. String cells over 2048 characters return `{value, truncated:true, totalLength}` with the first 2048 characters. Every string cell is masked before it is returned: a JSON header map (under any column name) has the values of redacted headers replaced with `<redacted>`, and bearer tokens, JWTs, long hex keys and `password=`-style values are masked in any text.

The query runs against the whole capture DB. Unlike the other read tools it ignores `session_open` and the attached session (the reply says `scope:"all-sessions"`), so filter on `session_id` yourself. It sees only what is on disk: `http_bodies.bytes` holds bodies as captured, and plaintext from `session_configure bodyDecryption` (kept in memory only) is not queryable here.

Times: `*_us` columns are microseconds since epoch; `sessions.started_at` / `ended_at`, `timestamp_ms`, `ts_ms`, `last_seen_ms` and `added_at` are milliseconds.

## Schema

```
sessions(id, started_at, ended_at, app_name, vm_service_uri, isolate_id, project_path, note)
session_attachments(session_id, pid, attached_at)
http_requests(session_id, vm_id, isolate_id, method, url, host, path, status_code, reason_phrase,
              start_us, end_us, duration_us, request_size, response_size, content_type,
              request_headers_json, response_headers_json, redirects_json, has_error,
              bodies_fetched, body_fetch_attempts)
http_bodies(session_id, vm_id, which, bytes, size)
socket_events(session_id, vm_id, isolate_id, socket_type, address, port, start_us, end_us,
              last_read_us, last_write_us, read_bytes, write_bytes)
log_records(id, session_id, isolate_id, timestamp_ms, source, level, logger, message, error,
            stack_trace, dedup_key)
alerts(id, session_id, ts_ms, severity, kind, title, detail, source_kind, source_id,
       signature, occurrence_count, last_seen_ms, last_source_id, drained)
ignored_hosts(host, added_at, reason)
capture_allow(pattern, added_at, reason)
redacted_headers(name, added_at, reason)
alert_patterns(id, kind, regex, severity, label, added_at)
tool_events(id, ts_ms, correlation_id, tool, outcome, arg_keys, duration_ms, result_bytes,
            estimated_tokens, error_kind, degraded)
http_search(url, content_request, content_response)   -- FTS5; rowid = http_search_map.rowid
http_search_map(rowid, session_id, vm_id, isolate_id)
```

`http_requests.content_type` is the response Content-Type, else the request's. `http_bodies.which` is `request` or `response`. `http_search` is the full-text index `network_search` reads (without body decryption); `SELECT m.vm_id FROM http_search JOIN http_search_map m ON m.rowid = http_search.rowid WHERE http_search MATCH 'token AND other' AND m.session_id = 14` gives you FTS5 operators that `network_search` does not expose.

**Size sentinels.** `http_requests.request_size` / `response_size` come straight
from the VM profiler's `contentLength`: `>= 0` is a real byte count (`0` = the
message genuinely had no body), and `-1` means the size was unknown ahead of the
body (chunked transfer-encoding, or no `Content-Length` header) — NOT "no body".
So `WHERE response_size = 0` finds genuinely-empty responses, while
`response_size = -1` is a streamed/chunked one whose true size is only known
after the body is read. The structured tools render `-1` as a `false` flag
instead of a misleading negative number (`sizeKnown` in `network_get`,
`requestSizeKnown` / `responseSizeKnown` in `network_list`), and `network_get`
pairs it with `bodyStatus` (`stored` / `empty` / `pending` / `unavailable`) so a
chunked-but-present body is never confused with an empty one.

## Args

- `sql` (string, required) — a single SELECT or WITH...SELECT statement.

## Returns

```json
{
  "summary": "3 row(s) returned.",
  "scope": "all-sessions",
  "rowCount": 3,
  "rows": [{"host":"api.x","n":12}, ...],
  "nextSteps": [
    "For HTTP bodies: network_body id:<vm_id> which:response",
    "For session details: session_open id:<n>"
  ]
}
```

`warnings` appears when the 500-row cap was hit (the summary adds `hit hard cap of 500`) or BLOB cells were summarized (the summary adds `BLOB cells summarized`). Zero rows gives the summary `Query returned no rows.`

Errors (all carry `nextSteps`):

| Cause | `errorKind` | Detail |
|---|---|---|
| `sql` missing or blank | `bad_argument` | ``Missing required arg `sql`.`` |
| Not a SELECT / `WITH ` statement | `bad_query` | `Only SELECT/WITH statements are allowed.` |
| A `;` left after trimming trailing ones | `bad_query` | `Multiple statements are not allowed.` |
| SQLite rejected the statement (unknown table/column, syntax) | `bad_query` | `sql failed: ...` plus a `schema` map of table name to column names (`http_search`, `http_search_map`, FTS shadow tables and `_meta` left out) |

## Pairs well with

- `session_list` — pick ids of interest before SQL.
- `network_search` — body content; SQL is for metadata.

## Example

```
> network_query sql:"SELECT host, COUNT(*) AS n FROM http_requests WHERE session_id=14 GROUP BY host ORDER BY 2 DESC"
< {summary:"3 row(s) returned.", rows:[{host:"api.example.com", n:32}, ...]}
```
