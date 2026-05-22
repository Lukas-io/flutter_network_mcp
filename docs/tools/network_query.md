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

Trims trailing semicolons. Rejects non-SELECT/WITH. Rejects multi-statement (any internal `;`). Wraps your statement in `SELECT * FROM (...) LIMIT 500` so the row cap applies regardless of your own LIMIT. BLOB cells return `{type:"blob", size:N}` to avoid dumping bytes. String cells > 2 KB return `{value, truncated, totalLength}`.

## Schema

```
sessions(id, started_at, ended_at, app_name, vm_service_uri, isolate_id, project_path, note)
http_requests(session_id, vm_id, method, url, host, path, status_code, reason_phrase,
              start_us, end_us, duration_us, request_size, response_size, content_type,
              request_headers_json, response_headers_json, has_error, bodies_fetched)
http_bodies(session_id, vm_id, which, bytes, size)
socket_events(session_id, vm_id, socket_type, address, port, start_us, end_us,
              last_read_us, last_write_us, read_bytes, write_bytes)
log_records(id, session_id, timestamp_ms, source, level, logger, message, error, stack_trace)
alerts(id, session_id, ts_ms, severity, kind, title, detail, source_kind, source_id, drained)
ignored_hosts(host, added_at, reason)
redacted_headers(name, added_at, reason)
alert_patterns(id, kind, regex, severity, label, added_at)
```

## Args

- `sql` (string, required) — a single SELECT or WITH...SELECT statement.

## Returns

```json
{
  "summary": "3 row(s) returned.",
  "rowCount": 3,
  "rows": [{"host":"api.x","n":12}, ...],
  "nextSteps": [
    "For HTTP bodies: network_body id:<vm_id> which:response",
    "For session details: session_open id:<n>"
  ]
}
```

`warnings: []` fires when the 500-row cap was hit OR BLOB cells were summarized.

## Pairs well with

- `session_list` — pick ids of interest before SQL.
- `network_search` — body content; SQL is for metadata.

## Example

```
> network_query sql:"SELECT host, COUNT(*) AS n FROM http_requests WHERE session_id=14 GROUP BY host ORDER BY 2 DESC"
< {summary:"3 row(s) returned.", rows:[{host:"api.example.com", n:32}, ...]}
```
