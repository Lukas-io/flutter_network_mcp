# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.6.0] — 2026-05-28

### Added — multi-attach

The MCP server can now hold **N concurrent attached sessions** — debug `sanga_mobile` and `sanga_driver` in the same DB, the same agent conversation, without losing either side. Each attach owns its own VM connection + 2-second capture writer + 500-entry log ring. Cap via `FLUTTER_NETWORK_MCP_MAX_ATTACH` env var (default 4, clamped 1–32). DB schema unchanged — zero migrations needed; the schema was already keyed by `session_id`.

Shipped across six commits (phases 1–6), summarized here:

- **Architecture** — `SessionRegistry.instance` holds a `Map<String, AttachedSession>` keyed on vmServiceUri. Each `AttachedSession` owns its `VmClient`, `CaptureWriter`, `LogBuffer`, `LogStreamSubscriber`, and capture-time flags (httpProfilingEnabled, socketProfilingEnabled, lastHttpCursor). The DTD client and DB stay singletons.
- **Scope resolver** (`lib/src/util/scope.dart`) — every read tool routes through `resolveScope(args)` at the top. Priority order: `sessionId` arg → `appNameContains` arg → history view (`session_open`) → `registry.soleAttached` (auto-resolve when exactly one is attached). With 2+ attached and no scope hint, returns a structured error listing every attached session + `nextSteps` like `sessionId:14  // sanga_mobile`. Successful responses carry a `scope:{sessionId, appName, isLive}` block so the agent can verify which session it just read from.
- **Per-session alerts** — `jsonResult` gained an optional `scopeSessionId` parameter so the auto-injected `pendingAlerts` field is scoped to the calling tool's session, not process-wide. No cross-app alert bleed in the push-like signal.
- **`network_attach`** — drops `force:true` arg entirely. Per-vmServiceUri duplicate guard (same app can't attach twice; different apps coexist). Returns `scope:{sessionId, appName, isLive:true}`. Catch block disconnects DTD only when this attempt brought DTD up AND no other sessions remain.
- **`network_detach`** — three modes: `sessionId` / `appNameContains` for one session, `all:true` to drop everything, zero-arg works only when exactly one is attached. DTD disconnects only when nothing remains.
- **`network_status`** — `attached` field is now a LIST of attached session records (sessionId, appName, vmServiceUri, isolateId, attachedAtMs, httpProfilingEnabled, socketProfilingEnabled). `attachedCount` top-level. `alerts.perAttached:[{sessionId, appName, pending}]` only when 2+ attached. `attachIfOne` still works, fires only when `attachedCount == 0`.

15 read tools threaded through the scope resolver: `network_list`, `network_get`, `network_body`, `network_clear`, `network_search`, `network_diff`, `network_replay`, `socket_list`, `socket_get`, `socket_clear`, `logs_tail`, `logs_clear`, `alerts_drain`, `alerts_peek`, `alerts_clear`. Each gained optional `sessionId:int` and `appNameContains:string` args. In single-attach mode (the common case) behaviour is unchanged — auto-resolve handles it without extra args.

### Added — env vars

- `FLUTTER_NETWORK_MCP_MAX_ATTACH` (default 4, clamped 1–32) — caps concurrent attachments.

### Changed

- **README "32 tools" table** now has a **Scope** column marking which tools accept `sessionId` / `appNameContains`. New "Multi-attach (0.6.0)" section explains the workflow.
- **`docs/README.md`** gained a multi-attach callout at the top.
- **`alerts_clear`** — was previously "default scope = all sessions"; now scoped per-session like every other tool so multi-attach can't accidentally cross-delete drained alerts. Cross-session bulk clear stays possible via `network_query`.

### Notes

- DB schema unchanged — existing 0.5.x / 0.6.x DBs work without migration.
- DTD client is shared across all attached sessions (one DTD knows about N apps; one connection per process).
- Single-attach workflows are unaffected — every tool auto-resolves to the sole attached session, no extra args.
- For cross-app correlation (e.g. finding matching request/response pairs across apps), use `network_query` SQL — explicit cross-session aggregation is out of the typed tool surface by design.
- Lays groundwork for 0.8.0 auto-attach via DTD isolate-discovery events.

## [0.5.18] — 2026-05-24

### Changed
- **Sharpened tool `description` fields** for 8 tools where an audit showed agents under-reaching because the description led with mechanism (FTS5 / SQL escape hatch / byte range / VM service streams / DTD) instead of use case. Each one now leads with WHEN to reach for it. Focus was on the entry-point tools (`network_status`, `network_attach`) plus the highest-leverage discovery / drilldown / housekeeping tools agents tend to skip:
  - `network_status` — opens with "Call this FIRST, every session" + explicit pointer that `knownApps` is the list to pick from for `network_attach`. Replaces "Auto-orienting first call" which didn't tell the agent *what* it was orienting toward.
  - `network_attach` — leads with the sequencing cue ("call this after `network_status` shows the app you want under `knownApps`") so the attach step has a clear place in the flow.
  - `network_search` — "Find a captured request by something inside it…" instead of "Full-text search…using SQLite FTS5".
  - `network_diff` — leads with the regression-hunting trigger ("a request that used to work now fails, or two similar-looking requests behave differently").
  - `network_query` — reframed from "SQL escape hatch" to a positive use-case list (aggregates, joins, percentile timings) + an explicit "reach for this AFTER" hint pointing at the cheaper typed tools.
  - `network_body` — leads with the exact trigger ("Call this whenever a network_get response carries `truncated:true`"), not the byte-range mechanism.
  - `logs_tail` — leads with concrete use cases (correlate a log with a nearby HTTP request, chase an exception spotted via alerts_drain) before live-vs-history mechanics.
  - `db_stats` — clarifies the practical triggers (before `db_vacuum`, investigating which tables grew, locating the DB file) instead of a flat "use when the file might be getting big".

### Added
- **README "32 tools" table now per-tool** — each row carries a WHEN-first one-liner so the user (and any agent reading the README) sees the cheatsheet at a glance, not just tool names grouped by category. Useful when reminding an agent that a specific tool exists for a job it isn't reaching for.
- **Issue templates restructured for agent-first filing.** Bug-report template lightened: a 3-field "Quick report" section is the only required content (what broke, failing tool call, `network_status` response); environment, repro steps, and stderr move into a collapsible "Optional detail" block. New **"UX friction / suggestion"** template (3 fields, no environment) for things that work but feel awkward, confusing, or unclear — previously these got funneled into the bug template and diluted. Server `instructions`, README "Found a bug?" section, and `docs/README.md` callout all rewritten to point at both templates and make the agent-first flow explicit ("YOU are the recommended channel for filing").

## [0.5.17] — 2026-05-24

### Added
- **Proactive bug-report directive** — appended to the MCP server's `instructions` string (loaded into every agent's context at handshake) telling agents to open an issue at https://github.com/Lukas-io/flutter_network_mcp/issues or hand the user a paste-ready body whenever they hit a bug / wrong output / missing field / confusing error / UX friction, without asking permission first. Mirror sections added to `README.md` ("Found a bug? File it") and `docs/README.md` (top-of-file callout) so the directive shows up wherever an agent or human lands. Goal: shorten the maintainer's discovery loop on a young package with a small user base.

## [0.5.16] — 2026-05-24

### Fixed
- **Crash on fresh install** when the default data dir is unwritable (first external bug report). `CapturesDatabase.open()` previously called `Directory.createSync(recursive: true)` against a single resolved path; on macOS boxes where a prior `sudo` installer left `~/.local` root-owned, this raised `PathAccessException: '/Users/<u>/.local/share' (errno = 13)` before MCP handshake could complete. The MCP host (Claude Code) swallows stderr, so the user only saw `flutter-network: ✗ Failed to connect`.
- **Stack-trace leak in `main()`** — `bin/flutter_network_mcp.dart` now catches `FileSystemException` + `StateError` from `CapturesDatabase.open()` and exits 73 (`EX_CANTCREAT`) with one actionable stderr line. No more raw Dart stack in the host log.

### Changed
- **`_resolveDataDir(override)` → `_candidateDataDirs(override)`** in `lib/src/storage/database.dart`. `open()` now walks a prioritized list and uses the first writable candidate; throws `StateError` listing every attempt + last OS error if all fail. Single-element list when `--data-dir` or `FLUTTER_NETWORK_MCP_DATA_DIR` is explicit (errors loudly — no silent fallback on user-named paths).
- **macOS default moved** from `~/.local/share/flutter_network_mcp` to `~/Library/Application Support/flutter_network_mcp` (canonical macOS path). Linux/other platforms unchanged.
- **macOS auto-migration (one-time, 0.5.16)**: on first launch, if `~/.local/share/flutter_network_mcp/captures.db` exists and the new location's `captures.db` does not, the server atomically renames the old dir to the new one (WAL/SHM files travel along) and emits a single stderr banner. If rename fails (cross-device, race, permissions) it leaves the old dir intact and the candidate walker falls back to it — no partial copy+delete, no corruption risk. Skipped entirely when `--data-dir` or `FLUTTER_NETWORK_MCP_DATA_DIR` is set.

### Added
- **`FLUTTER_NETWORK_MCP_DATA_DIR`** env var — parity with the existing `--data-dir` flag and with the other startup knobs (`FLUTTER_NETWORK_MCP_DTD_URI`, `FLUTTER_NETWORK_MCP_POLL_MS`, etc.).
- README: per-platform default-path table + 0.5.16 migration callout + DB-segmentation paragraph explaining that captures partition by `session_id` (one row per `network_attach`, with `app_name` as filter metadata).

### Notes
- The reporter's first proposed fix (adding `recursive: true` to the `createSync` call) was already in place since 0.5.0 — the EACCES fired *because* `recursive: true` was walking up to `~/.local` and finding it root-owned. The real fix is the candidate fallback chain.

## [0.5.15] — 2026-05-22

### Changed
- **Live mode is now push-like.** `jsonResult()` (used by every success response across all 32 tools) auto-annotates a top-level `pendingAlerts: {count, critical?}` field when the alerts capability is on, the DB is open, and there are undrained alerts in scope. The agent no longer has to poll `network_status` to discover that alerts have accumulated — any tool call surfaces the count.
  - Shadow-skipped on tools that already report alerts in richer shapes (`alerts_drain`, `alerts_peek`, `network_status`) or have their own `pendingAlerts` field (`db_stats`).
  - Best-effort: any DB hiccup falls through silently — never blocks a tool response.
  - Skipped entirely when `--disable alerts` is set.

## [0.5.14] — 2026-05-22

### Changed
- **`docs/tools/` reorganized into 11 use-case subfolders** so listing the directory no longer dumps 32 flat files. Moves done via `git mv` so file history is preserved. Each subfolder gets its own `README.md` orienting the agent within it. Top-level `docs/README.md` index updated to link the new paths.

```
docs/tools/
├── lifecycle/        (3) network_status, network_attach, network_detach
├── finding/          (2) network_list, network_search
├── inspecting/       (2) network_get, network_body
├── comparing/        (2) network_diff, network_replay
├── what-went-wrong/  (3) alerts_drain, alerts_peek, logs_tail
├── history/          (5) session_list, session_open, session_close, session_export, session_note
├── tuning/           (4) alerts_config, alert_patterns, ignored_hosts, redacted_headers
├── reset-live/       (4) network_clear, socket_clear, logs_clear, alerts_clear
├── db-management/    (4) db_stats, bodies_purge, session_delete, db_vacuum
├── sockets/          (2) socket_list, socket_get
└── power/            (1) network_query
```

## [0.5.13] — 2026-05-22

### Fixed
- README: corrected stale tool count ("Twenty-five tools" → "Thirty-two tools") and stale entry-file reference (`bin/main.dart` → `bin/flutter_network_mcp.dart` — renamed in 0.5.2 for the install path fix).
- README + `docs/README.md`: corrected stale alert-counter field (`alerts.pending` → `alerts.pendingTotal` / `critical`, post-0.5.1 split).
- Code comments in `alert_patterns.dart` + `capabilities.dart` still referenced `bin/main.dart`. Updated.

### Added
- README — new "The agent-facing contract" section documenting the consistent response shape every tool follows (`summary` / `nextSteps` / `warnings`, error structure, confirm-guards on destructive ops).
- `docs/README.md` — restructured around USE CASES (Getting started, Finding a request, Inspecting one request, Comparing/reproducing, What went wrong, Investigating history, Tuning capture, Resetting live state, Managing the DB, Sharing/exporting, Sockets, Power user, Wrapping up). Tools that serve more than one job (e.g. `network_replay` for both compare+share) appear under each. The original capability-based index is preserved below for `--capabilities` / `--disable` flag mapping.
- `.github/ISSUE_TEMPLATE/bug_report.md` — captures DTD URI freshness, dart version, server invocation, and `network_status` output upfront so the most common debug context lands in the first comment.

## [0.5.12] — 2026-05-22

### Changed
- **Batch 6 (SQL + Admin)** — final six tools through the checklist. Phase 6 sweep complete: all 32 tools now follow the checklist.
  - `network_query` — `summary` reports row count + cap-hit + BLOB-summarized status; `warnings` for 500-row cap hits and BLOB summarization; `nextSteps` points at `network_body` / `session_open` for follow-up.
  - `ignored_hosts` — every action has a `summary`; add-action warns when matching rows already exist in history; `list` action suggests `network_query` to find noisy hosts to add.
  - `redacted_headers` — every action has a `summary`; built-in additions return success with `inserted:false` + warning; built-in removal still errors with a clear explanation.
  - `db_stats` — `summary` synthesizes ("DB at X MB across N session(s) (Y MB in bodies, Z undrained alert(s))."); `warnings` for big DB (>100 MB), body-dominant (>70%), many sessions (≥50); capability-aware `nextSteps`.
  - `db_vacuum` — `summary` shows reclaimed bytes ("Vacuumed: 45.20 MB → 7.10 MB (38.10 MB reclaimed)."); `warnings` when no space reclaimed (suggesting deletes first).
  - `bodies_purge` — dry-run now reports `wouldPurgeRows` + `wouldPurgeBytes` (added `countPurgeableBodies` DAO method behind it) so the agent can echo the impact before committing.

### Added
- `CapturesDao.countPurgeableBodies({sessionId, olderThanMs})` — mirror of `purgeBodies` filters for dry-run impact reporting.

## [0.5.11] — 2026-05-22

### Fixed
- `session_delete` dry-run and `session_export` were reporting all per-session counts as 0 because `dao.getSession(id)` returns the raw row without COUNT joins. Added `CapturesDao.getSessionWithCounts(id)` (joins COUNT subqueries for http_requests / socket_events / log_records / alerts), and pointed both tools at it.

### Changed
- **Batch 5 (Sessions)** — all six session tools through the checklist:
  - `session_list` — `summary` ("3 session(s) — live: 14, viewing: live."); per-row null fields (vmServiceUri, isolateId, note, endedMs) omitted; `warnings` for empty/large session count; `nextSteps` suggests `session_open` on a pickable id + `session_delete` when count ≥ 50.
  - `session_open` — `summary` describes the opened session in one line; reports `isLive` and `isEnded` flags; `warnings` when you open the live session (no-op); `nextSteps` for read tools + close.
  - `session_close` — `summary` distinguishes no-op vs. revert; `nextSteps` adapt based on whether live session exists.
  - `session_export` — pre-flight validates session id; reports `sizeBytes` and per-counts; `warnings` for live (snapshot), overwritten file, empty-HAR; `nextSteps` for opening in Chrome DevTools / cat+jq.
  - `session_note` — `summary` echoes truncated note; `nextSteps` suggests `session_list` + `session_export`.
  - `session_delete` — dry-run now includes per-counts ("would delete 38 http, 12 log(s), 3 socket(s)"); confirmed delete adds `warnings` reminding `db_vacuum` is needed to reclaim disk.

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
