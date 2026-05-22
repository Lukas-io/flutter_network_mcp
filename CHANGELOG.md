# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.5.10] — 2026-05-22

### Changed
- **Batch 4 (Alerts)** — all five alert tools through the checklist:
  - `alerts_drain` / `alerts_peek` — shared `buildAlertsResponse()` so both stay consistent. `summary` includes per-severity breakdown ("Drained 5 alert(s) session 14: 1 critical, 2 error, 2 warning"). Per-alert null fields (`detail`/`sourceKind`/`sourceId`) omitted. `nextSteps` points at `network_get` for the first HTTP-source alert and `logs_tail` for the first log-source alert (capability-gated).
  - `alerts_config` — `summary` lists enabled/disabled rule keys. `mutated` field tells the agent whether `set` was applied. `warnings` for all-rules-disabled and dangerously-low `slowThresholdMs`. `nextSteps` differs based on get vs mutate.
  - `alerts_clear` — added `confirm:true` requirement for `drainedOnly:false` (deleting undrained alerts is destructive). Reports `remainingPending` so the agent knows when the queue is clean. `summary` describes filter scope.
  - `alert_patterns` — every action returns a `summary` and tailored `nextSteps`. `warnings` for overly-broad patterns (`.*` / `.+`). Error paths include `nextSteps` with concrete retry guidance.
- All Batch 4 errors carry `nextSteps` with concrete recovery commands.

## [0.5.9] — 2026-05-22

### Changed
- **Batch 3 (Logs)** — both log tools through the checklist:
  - `logs_tail` — `summary` reports count + severe-level breakdown + active filters ("12 record(s), 2 severe (level ≥ 1200); filtered by level≥900"). `severeCount` field surfaces high-priority entries. `warnings` for stream-not-subscribed, buffer-near-rotation (≥480/500), no-match-on-filters. `nextSteps` points at `alerts_drain` when severe records present (and alerts capability on), `logs_tail since:` for incremental polling. Per-entry null fields (level/loggerName/error/stackTrace) omitted.
  - `logs_clear` — `clearedCount` reports how many records were dropped (so the agent can echo it). `summary` clarifies the DB is untouched. `nextSteps` for verification.

## [0.5.8] — 2026-05-22

### Changed
- **Batch 2 (Sockets)** — all three socket tools through the checklist:
  - `socket_list` — `summary` reports counts + open/closed split ("3 socket(s) (1 open) in session 14"); null timing fields omitted per-row; `warnings` for empty profile; `nextSteps` points at `socket_get` for top, `network_list` for correlated HTTP traffic.
  - `socket_get` — `summary` ("TCP api.example.com:443 — 12345 bytes read, 456 bytes written (open)."); `nextSteps` suggests `network_list hostContains:` for HTTP correlation, plus "re-call later" hint when socket is still open.
  - `socket_clear` — clearer `summary` + explicit `warnings` reminding the DB is untouched.
- All Batch 2 errors carry `nextSteps` (e.g., "network_status — confirm socketProfilingEnabled").

## [0.5.7] — 2026-05-22

### Changed
- **Batch 1 (HTTP + Search)** — all six tools brought to the [tool review checklist](https://github.com/Lukas-io/flutter_network_mcp/blob/main/docs/README.md) in one pass:
  - `network_body` — `summary`, `nextSteps` (paging hint when `nextOffset` set; replay/diff when complete), `warnings` for utf8-on-binary, offset-clamped, and history-not-yet-persisted; error paths now have `nextSteps`.
  - `network_clear` — clearer `summary` + explicit `warnings` reminding the DB is untouched; `nextSteps` for `network_list` and `bodies_purge`/`session_delete` (the actual destructive ops).
  - `network_diff` — `summary` ("POST /login → 500 vs POST /login → 200 → differs: status, 1 header, body."); `statusDiff`/`methodDiff`/`urlDiff` omitted when unchanged (token savings); `warnings` consolidates body-not-comparable cases; rejects `idA == idB`.
  - `network_replay` — `summary`, `headerCount`, `redactedHeaders`, `bodyIsBinary` reported; `warnings` for binary body, truncation, and `redact:false`; `nextSteps` includes "Paste the curl into your terminal".
  - `network_detach` — counts captured rows (http/logs/alerts) for the just-ended session and includes them in the response summary + `captured` block; `nextSteps` points at `session_open`/`session_list`/`network_attach`.
  - `network_search` — `summary`, BM25-aware `nextSteps` (top match + 2-way diff when ≥2), empty-result `warnings` hint at backfill delay.
- All Batch 1 tools now follow the consistent error shape `{error, contextual fields, nextSteps}`.
- Per-tool docs in `docs/tools/` rewritten to match new args, returns, and error shapes.

## [0.5.6] — 2026-05-22

### Changed
- `network_get` brought up to the [tool review checklist](https://github.com/Lukas-io/flutter_network_mcp/blob/main/docs/README.md) in one pass:
  - Adds `summary` line ("GET /feed/vendors → 200 OK · 372ms · application/json").
  - Adds capability-aware `nextSteps` — points at `network_body` first when bodies are truncated, then `network_replay` and `network_diff`. All gated on the `http` capability.
  - Adds top-level `warnings: []` array for body truncation, in-flight requests, transport errors, and (history mode) not-yet-backfilled bodies. Omitted when healthy.
  - Lifecycle `events` array is now opt-in via `includeEvents:true` (default false). When included, capped at 50 entries with `_omitted` count.
  - Null-valued fields throughout (endTimeMs, durationMs, statusCode, reasonPhrase, cookies, etc.) omitted per-record so partial requests don't return placeholder nulls.
  - Hard caps documented on every truncation arg: bodyTruncateBytes ≤ 262144, headerTruncateBytes ≤ 4096.
  - All error paths now include `nextSteps` with concrete recovery commands.

## [0.5.5] — 2026-05-22

### Changed
- `network_list` brought up to the same shape as `network_attach` / `network_status` in one pass against the [tool review checklist](https://github.com/Lukas-io/flutter_network_mcp/blob/main/docs/README.md):
  - Adds `summary` (one-line synthesis) and capability-aware `nextSteps` (1–3 actions; e.g., points at `network_search` only when search is enabled, `alerts_drain` only when alerts are enabled).
  - Adds `warnings: []` for partial / degraded states: empty profile right after attach, all filters excluded, cursor produced no new captures, filter dropout >5×. Omitted when healthy.
  - Per-request summaries now OMIT null-valued fields (statusCode, durationMs, contentType, etc.) — saves ~30% tokens per row on incomplete requests.
  - Error returns now include `nextSteps` with concrete recovery commands (network_status / network_attach / session_open for "not attached"; check zombie state for VM call failures).
  - Arg descriptions tightened — `since` now explicitly explains incremental-by-default and `pass nextCursor here` usage.

## [0.5.4] — 2026-05-22

### Changed
- `network_attach` response polish:
  - Adds a one-line `summary` field the agent can echo verbatim ("Attached to <app> — capturing HTTP+sockets+logs into session N.").
  - Adds a `warnings: []` array that surfaces partial degradation (socket profiling unavailable, log stream subscription failed, HTTP timeline did not enable cleanly). Omitted when everything is healthy.
  - `nextSteps` is now capability-aware — tools the user disabled via `--capabilities`/`--disable` never appear in the suggested follow-ups.
  - Removed always-true / redundant fields from the success payload: `httpProfilingEnabled`, `logStreamActive`, `capturesDbPath`. Saves ~50 tokens; the DB path is already in `network_status`, and the other two are implicit on a successful return.
  - Honors capability gates while attaching: skips socket profiling if `sockets` is disabled, skips log stream subscription if `logs` is disabled (instead of trying and silently failing).
- `network_attach` no-DTD-URI error: rewrote the `nextSteps` to acknowledge the agent can't restart Claude Code itself — now suggests asking the user for the URI and updating `.mcp.json`.

## [0.5.3] — 2026-05-22

### Changed
- `network_attach`:
  - Adds `appNameContains` arg for case-insensitive substring filtering when DTD has multiple apps — no need to round-trip through an error and construct a `vmServiceUri`.
  - Adds `force` flag (default false). Calling attach while already attached now errors with `currentApp` + `liveSessionId` and a `nextSteps` hint, instead of silently detaching. Pass `force:true` to restore the prior behavior.
  - Strips `stackTrace` from `structuredContent` (writes to stderr instead) so error responses stay context-cheap.
  - All error returns now include a `nextSteps` array with 1–2 concrete recovery actions. Zombie-DTD errors specifically suggest restarting the Flutter app.
- `network_status` gains `attachIfOne` arg (default false). When true AND not already attached AND DTD reports exactly one app AND a default URI exists, the call auto-attaches in the same response. The full attach result lands under `autoAttached`.

### Refactored
- The attach core logic moved to a shared `performAttach()` function so both the `network_attach` tool and `network_status.attachIfOne` reuse the same code path.

## [0.5.2] — 2026-05-22

### Fixed
- **Install path** — `dart pub global activate` was emitting "Could not find bin/flutter_network_mcp.dart" because the entry file was `bin/main.dart` but the `executables:` pubspec entry expected the package-named file. Renamed `bin/main.dart` → `bin/flutter_network_mcp.dart` so the default convention matches and the installed binary actually runs.

## [0.5.1] — 2026-05-22

### Changed
- `network_status` now auto-orients:
  - Opportunistically connects to DTD when `defaultDtdUri` is set and the connection isn't already open, so `knownApps` populates on the very first status call. Pass `connectDtd:false` for purely passive checks.
  - Compresses `capabilities` to the string `"all"` when every category is enabled (saves ~30 tokens on the typical case).
  - Adds DB-level context: `dbPath` and `sessionCount`.
  - Splits alert counts into `pendingCurrent` (in scope), `pendingTotal` (across all sessions), and `critical` so stale alerts from past sessions surface even when not attached.
  - Adds a `nextSteps` array with 1–2 short, context-aware hints (e.g., "Multiple apps visible (2); call network_attach with explicit vmServiceUri").

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
