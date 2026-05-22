# Tool reference for agents

Per-tool guidance for `flutter_network_mcp`. Each tool has its own file with a **DO NOT USE THIS TOOL WHEN** section at the top — read those first. Negative flags catch ~70% of misuse before it happens.

## Index

### Lifecycle (always available)
- [`network_status`](tools/network_status.md) — current attachment, capabilities, pending alerts
- [`network_attach`](tools/network_attach.md) — open a capture session
- [`network_detach`](tools/network_detach.md) — close + finalize the session

### HTTP — gated by `--capabilities http`
- [`network_list`](tools/network_list.md) — paginated summaries with filters
- [`network_get`](tools/network_get.md) — one request, full headers + truncated body
- [`network_body`](tools/network_body.md) — byte-range body fetch
- [`network_clear`](tools/network_clear.md) — wipe live HTTP profile
- [`network_diff`](tools/network_diff.md) — diff two captured requests
- [`network_replay`](tools/network_replay.md) — emit a curl command

### Sockets — gated by `--capabilities sockets`
- [`socket_list`](tools/socket_list.md) — TCP/UDP stats
- [`socket_get`](tools/socket_get.md) — one socket detail
- [`socket_clear`](tools/socket_clear.md) — wipe live socket profile

### Logs — gated by `--capabilities logs`
- [`logs_tail`](tools/logs_tail.md) — recent log/stdout/stderr
- [`logs_clear`](tools/logs_clear.md) — wipe the live ring buffer

### Alerts (proactive issue surfacing) — gated by `--capabilities alerts`
- [`alerts_drain`](tools/alerts_drain.md) — return AND clear pending alerts
- [`alerts_peek`](tools/alerts_peek.md) — see pending alerts without clearing
- [`alerts_config`](tools/alerts_config.md) — read/tune detection rules
- [`alerts_clear`](tools/alerts_clear.md) — bulk-delete drained alerts
- [`alert_patterns`](tools/alert_patterns.md) — add project-specific regex rules

### Search — gated by `--capabilities search`
- [`network_search`](tools/network_search.md) — FTS5 full-text search of urls + bodies

### Sessions (persistence + history) — gated by `--capabilities sessions`
- [`session_list`](tools/session_list.md) — past capture sessions
- [`session_open`](tools/session_open.md) — switch read pointer to history
- [`session_close`](tools/session_close.md) — revert read pointer to live
- [`session_export`](tools/session_export.md) — write HAR / NDJSON
- [`session_note`](tools/session_note.md) — freeform note on a session
- [`session_delete`](tools/session_delete.md) — permanently remove a session + all its data

### SQL escape hatch — gated by `--capabilities sql`
- [`network_query`](tools/network_query.md) — read-only SELECT against captures DB (BLOB-safe, cell-capped)

### Admin — gated by `--capabilities admin`
- [`ignored_hosts`](tools/ignored_hosts.md) — allowlist of hosts the writer skips
- [`redacted_headers`](tools/redacted_headers.md) — extend network_replay's redaction set
- [`db_stats`](tools/db_stats.md) — DB size + row counts
- [`db_vacuum`](tools/db_vacuum.md) — reclaim disk after deletes
- [`bodies_purge`](tools/bodies_purge.md) — drop BLOBs, keep metadata
- (session_delete + alerts_clear live in their normal categories)

## Investigation playbook

1. `network_status` first. If `alerts.pending > 0`, call `alerts_drain`.
2. If the user described a symptom in plain language ("auth failed"), `network_search query="<the words>"`.
3. If they referenced a past session, `session_list` then `session_open`.
4. Found a candidate request? `network_get` for full detail; `network_body` for byte ranges if `truncated:true`.
5. Need to compare two requests? `network_diff`.
6. Want to reproduce a request from the terminal? `network_replay`.
7. Filing a bug for a coworker? `session_export id=<n> format=har`.

## Context-budget rules (the server enforces these)

- Summary tools never return bodies. They give sizes, you fetch bodies on demand.
- Hard caps on every list/range tool. Default 50, max 200 for HTTP lists. Bodies: default 4 KB truncated, max 256 KB per byte-range call.
- Cursors everywhere. Don't refetch — pass `since` / `nextCursor`.
- Server-side filtering. Use `method`, `hostContains`, `statusMin/Max`, `levelMin`, `loggerContains`.
