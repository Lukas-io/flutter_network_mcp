---
tool: network_query
description: Read-only SQL escape hatch against the captures DB. Single SELECT (or WITH...SELECT). 500-row cap.
when_to_use: When the structured tools can't express the question — joins across tables, aggregations, ad-hoc analysis.
---

## DO NOT USE THIS TOOL WHEN

- A purpose-built tool exists — `network_list` for filtered summaries, `network_search` for FTS, `alerts_drain` for alerts. Reach for SQL only when those can't express the question.
- You want to mutate data — this tool rejects anything that isn't SELECT / WITH...SELECT. Use the DB tools or open the file directly.
- The user wants a quick overview — SQL output is raw; for human-friendly summaries use the structured tools.
- You're tempted to write a 5-table join because it's powerful — start simpler. Cumulative cost of repeatedly re-reading raw SQL output is high; structured tools have summary fields that fit context better.

## Use this when

- "Show me request count by host across all sessions" — a GROUP BY query.
- "Average duration of POSTs to /api/* in the last hour" — aggregation.
- Cross-table joins (e.g., http_requests + log_records by time proximity).
- Schema exploration: `SELECT name FROM sqlite_schema WHERE type='table'`.

## How it works

Trims trailing semicolons. Rejects anything not starting with SELECT / WITH (case-insensitive). Rejects multiple statements (any `;` inside). Appends `LIMIT 500` to whatever you submit. Runs synchronously; no transaction wrapping.

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
```

## Args

- `sql` (string, required) — a single SELECT or WITH...SELECT statement.

## Returns

```json
{"rowCount": 3, "rows": [{"host":"api.x","n":12}, ...]}
```

## Pairs well with

- `session_list` — once you find ids of interest in SQL, open them.
- `network_search` — for body content; SQL is for metadata.

## Example

```
> network_query sql:"SELECT host, COUNT(*) AS n FROM http_requests WHERE session_id=14 GROUP BY host ORDER BY 2 DESC"
< [{host:"api.example.com", n:32}, {host:"cdn.example.com", n:8}]
```
