# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.5.0] — 2026-05-21

### Added
- **Storage management tools**: `session_delete` (with cascade + dry-run), `bodies_purge` (drop BLOBs, keep metadata), `db_stats` (file size, row counts, body bytes), `db_vacuum` (WAL checkpoint + VACUUM + optimize), `alerts_clear` (bulk delete, drained-only by default).
- **Project-level configurability tools**: `redacted_headers` (extend `network_replay`'s redaction set) and `alert_patterns` (add custom regex rules the detector evaluates alongside built-ins).
- **Env-based startup knobs**: `FLUTTER_NETWORK_MCP_POLL_MS` (50–60000ms), `FLUTTER_NETWORK_MCP_LOG_BUFFER` (50–10000 entries).
- Tool docs for the 7 new tools in `docs/tools/`.

### Changed
- `network_get` — added `headerTruncateBytes` (default 256). Long header values now return `{value, truncated, totalLength}`.
- `network_diff` — added `maxLineLength` (default 2000, hard cap 8000). Body diff hunks no longer leak huge minified-JSON lines verbatim.
- `network_replay` — body now truncates by default (`bodyTruncateBytes`, default 4096, hard cap 256 KB). Response includes `bodyTotalSize` + `bodyTruncated` flags. Uses runtime redacted-headers set instead of hardcoded list.
- `network_query` — wraps user SQL in a subquery so the 500-row cap doesn't collide with a user-supplied `LIMIT`. BLOB cells return `{type:'blob', size:N}`; string cells >2 KB return `{value, truncated, totalLength}`.
- Search content-type allowlist expanded (`application/ld+json`, `application/vnd.api+json`, `application/problem+json`).

### Migrations
- Schema v2 → v3: adds `redacted_headers` and `alert_patterns` tables.

## [0.4.0] — 2026-05-21

### Added
- **Zombie-DTD detection**: `network_attach` wraps `getVersion()` in a 5-second timeout and raises a clear error rather than hanging when the DTD is stale.
- **FTS5 full-text search**: `network_search` over URLs + utf8-decoded request/response bodies, with BM25 ranking and «highlighted» snippets. Queries are phrase-quoted by default so hyphens and special chars work naturally.
- **Live alerts pipeline**: `alerts_drain`, `alerts_peek`, `alerts_config`. Rules: `http_5xx`, `http_4xx`, `http_error`, `http_slow` (>3000ms default), `log_keyword` (regex on log messages), `flutter_error` (FlutterError / RenderFlex overflow / null-check / setState-after-dispose / type errors).
- **Capability gating**: `--capabilities http,sessions` allowlist / `--disable sockets,sql` denylist. Disabled tools don't appear in `tools/list` and disabled capture paths don't run. Categories: `http`, `sockets`, `logs`, `alerts`, `search`, `sessions`, `sql`, `admin`. Lifecycle (`status`/`attach`/`detach`) is always on.
- **Productivity tools**: `network_diff` (structural diff of two captured requests), `network_replay` (emit curl command with auth-header redaction), `session_note` (annotate sessions), `ignored_hosts` (capture-time host allowlist).
- **Per-tool docs in `docs/tools/<name>.md`** — Claude-skill-style with a `## DO NOT USE THIS TOOL WHEN` section placed BEFORE use cases.
- `network_status` now reports active capabilities + pending alert count.

### Migrations
- Schema v1 → v2: adds `alerts`, `ignored_hosts`, `http_search` (FTS5), `http_search_map` tables.

## [0.3.0] — 2026-05-21

### Added
- **Persistent capture sessions** in SQLite at `${XDG_DATA_HOME:-~/.local/share}/flutter_network_mcp/captures.db` (overridable via `--data-dir`). The capture writer polls the VM service every 2s and persists HTTP requests + headers + bodies (as BLOBs), socket events, and log records.
- **Live/history branching** — all read tools (`network_list/get/body`, `socket_list/get`, `logs_tail`) check `session.viewedSessionId`. If null → live VM service. If set → DB query.
- **Session tools**: `session_list`, `session_open`, `session_close`, `session_export` (HAR 1.2 or NDJSON).
- **SQL escape hatch**: `network_query` — read-only `SELECT` / `WITH...SELECT` with a 500-row cap.

## [0.2.0] — 2026-05-21

### Added
- Cursors and server-side filters on `network_list` (`since`, `method[]`, `hostContains`, `statusMin/Max`, `limit`).
- Body truncation in `network_get` (`bodyTruncateBytes`, default 4 KB) with `{truncated, totalSize}` metadata.
- `network_body` — byte-range fetch with hard 256 KB cap and `nextOffset` for paging.
- Socket profiling tools: `socket_list`, `socket_get`, `socket_clear`.
- Log streams subscription (`Logging` / `Stdout` / `Stderr`) → bounded 500-entry ring buffer + `logs_tail` / `logs_clear`.

## [0.1.0] — 2026-05-21

### Added
- Initial stdio MCP server built on `package:dart_mcp` 0.5.x.
- DTD connect + app discovery via `package:dtd` 4.x.
- VM service connect + HTTP profile RPCs via `package:vm_service` 15.x.
- Five Phase 1 tools: `network_status`, `network_attach`, `network_list`, `network_get`, `network_detach`.
- `tool/probe.dart` diagnostic for verifying DTD/VM connectivity outside the stdio loop.
