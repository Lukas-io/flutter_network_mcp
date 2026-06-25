# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.9.5] — 2026-06-25

### Added — network_report (one-call session health triage)

Capstone of the 0.9.x line. New tool: in one call, returns the worst error endpoints (ranked by error-rate x volume), the slowest endpoints (p95), pending alert count, and a **recommended next action** tailored to what is actually wrong, e.g. "Top problem: POST /login is failing 100% of 5 calls" -> network_search + network_drift it. Insight, not raw rows: the orientation call to run after network_status. Synthesizes the per-endpoint aggregator, the alert pipeline, and points at the 0.9.x tools (network_drift, alerts_drain). 264 tests green.

## [0.9.4] — 2026-06-25

### Added — network_replay_as_test (captured request -> runnable Dart test)

New tool: emits a runnable Dart test (package:http + package:test) that replays a captured request and asserts its status code (optionally `assertBodyContains`). Uses a uniform `http.Request` so every method + body works. Auth headers are redacted (commented out) by default so the test is shareable; the agent fills in real credentials. Lets the agent iterate a regression test instead of re-driving the app (FUTURE_FEATURES backlog #1). 261 tests green.

## [0.9.3] — 2026-06-25

### Added — network_drift (response shape-drift detection)

New tool: detects when an endpoint's response JSON contract changes mid-session. Decodes the captured JSON responses for a filtered endpoint (hostContains / pathContains), flattens each to a keyPath->type shape, and reports fields `added`, `removed`, or `changed` type vs the first sample, plus `firstDriftAt` (the request id + time where it changed). Answers "did the API contract drift" without eyeballing bodies. int/double both map to `number` and a lone null sample is ignored, so no false drift. Pure shape helpers (`jsonShape`, `diffShapes`) are tested. 258 tests green.

## [0.9.2] — 2026-06-25

### Added — network_diff_session ("what changed between two runs")

New tool: diffs the current session against a baseline session by endpoint (method + host + pathTemplate, ids collapsed). Returns `newEndpoints` (appeared today), `goneEndpoints` (disappeared), and `changed` (a material error-rate shift >= 0.1 or a p95 latency regression of 2x either way, with now/baseline/delta). Answers "what is different about today's run" in one call instead of eyeballing two network_summarize outputs. Reuses the network_summarize per-endpoint aggregator; diff logic is a pure, tested function. 253 tests green.

## [0.9.1] — 2026-06-25

### Added — token-budget-aware responses

`network_list` accepts a `maxTokens` budget (per-call, or a sticky `session_configure maxResponseTokens` default that applies session-wide). When set, the requests array is trimmed newest-first to fit, and the response reports `budget: {maxTokens, dropped}` plus a warning to page or raise the budget. Telemetry showed `network_list` is by far the heaviest tool (~11k tokens/call, ~46k max), so this directly reins in the agent's biggest context cost. Applies to both live and history reads; a tiny budget always keeps at least one row. Shared `trimToTokenBudget` helper. 249 tests green; logs_tail extension to follow.

## [0.9.0] — 2026-06-25

### Added — Tier-2 telemetry: recovery paths + self-correction effectiveness

Measures whether the agent-intuitive features actually work, pure aggregation over the Tier-1 data (no new capture, no DB migration).

- **Outcome-tagged transitions**: every tool->next-tool edge now carries `fromOutcome` (the prior call's ok/error/empty). Turns the playbook into recovery paths, "when network_get errors, what does the agent do next?"
- **`selfCorrection`**: after a tool returned an error/empty (and therefore a recovery payload, errorKind nextSteps, inline schema, or availableHosts), did the NEXT call in the same turn succeed? Reported per (tool, signal) with `occurrences` / `recovered` / `recoveryRate`. This is the direct measure of whether schema-on-error and availableHosts actually help.

Collector: `tool_transitions` gains `from_outcome`; new `tool_self_correction` table; `migrations/002-tier2-recovery.sql` migrates an existing deployment; README documents the recovery-path + effectiveness queries. Privacy-safe (counts only). 245 tests green.

## [0.8.15] — 2026-06-25

### Added — Tier-1 telemetry datapoints (error composition, context cost, degradation)

Three richer signals now flow through the usage pipeline, so analysis answers "why", not just "how often". Schema v8 to v9.

- **`errorKinds`** per tool: error calls are broken down by their typed `ErrorKind` (`bad_argument` / `unresponsive_vm` / `not_found` / ...). Turns a flat error rate into an actionable composition, `bad_argument`-heavy means the schema/docs confuse agents; `unresponsive_vm` means infra; `not_found` means stale ids.
- **`degraded`** per tool: counts calls that fell back from the primary path (live VM read to DB snapshot), a direct measure of live-path reliability.
- **`estimated_tokens`** is now shipped to the collector (captured locally since 0.8.14 but not stored server-side), so context-cost ranking is first-class.

`tool_events` gains `error_kind` + `degraded` columns (v8 to v9 migration). `usage_stats` surfaces all three. Collector: `tool_stats` gains `estimated_tokens` + `degraded`, plus a new `tool_error_kinds` table; `collector/migrations/001-tier1-datapoints.sql` migrates an existing deployment. All privacy-safe (kinds, counts, sizes; never values/URLs/bodies). 243 tests green.

## [0.8.14] — 2026-06-14

### Changed — token usage tracking in usage_stats

Adds estimated token cost tracking to the tool-usage telemetry pipeline (schema v8).

- Every tool call now records `estimated_tokens` (result text length / 4, a UTF-8 approximation) alongside the existing `result_bytes` in the `tool_events` table.
- `usage_stats` surfaces two new per-tool fields: `avgEstimatedTokens` (mean tokens per call) and `totalEstimatedTokens` (lifetime sum). The top-level response also gains `totalEstimatedTokens` across all tools in the window.
- Schema migrated v7 to v8 via `ALTER TABLE tool_events ADD COLUMN estimated_tokens INTEGER`. Additive; existing rows get NULL and are excluded from averages.
- 216 tests green; `dart analyze` clean.

## [0.8.13] — 2026-06-13

### Changed — compact, accurate tool definitions

Rewrote every tool `description` and schema-property description (and the server `instructions` field) for the agent's handshake budget: one tight sentence on when/what plus the key constraint, dropping version tags, markdown, mechanism history, em dashes, and anything the schema already states. The recurring params (`sessionId` / `appNameContains` / `isolateId` / `since`) are standardized to one short phrasing across all read tools.

- The `tools/list` handshake payload drops from **~46 KB to ~29 KB (about 36% off)**, so every agent session loads a leaner, sharper surface. ~16.9 KB of description text cut across 37 files.
- Accuracy preserved: each tool still states when to reach for it and its one gotcha. No behaviour change (descriptions are strings); 216 tests still green.
- The usage telemetry (live since 0.8.12) will show which tools get mispicked or never called, to guide further pruning with data instead of guesses.

## [0.8.12] — 2026-06-12

### Changed — telemetry collector is live

The Cloudflare Worker + D1 collector (added under `collector/`) is deployed, so `kCollectorEndpoint` now points at it instead of being empty. Crash reports (0.7.1) and usage rollups (#79) now POST to the collector in addition to the local tamper-evident audit log. One endpoint receives both; the worker routes by payload `kind`.

- **No behaviour change beyond the network send.** Same payloads, same privacy guarantees (only `machine_hash` + aggregate/error shape, no PII / URLs / bodies / arg values), same audit log recording byte-for-byte what was sent. Opt out with `FLUTTER_NETWORK_MCP_NO_TELEMETRY=true` (or `FLUTTER_NETWORK_MCP_NO_USAGE=true` for usage only).
- Verified end-to-end against the deployed collector: health, a usage rollup (fanned into per-tool stats + transitions), and a crash report all round-trip; test data was then cleared.
- The collector is queryable for the "how do agents use the tools" event-tracking the analytics were built for: see `collector/README.md`.

## [0.8.11] — 2026-06-12

### Fixed — `network_list` "No HTTP captured yet" was misleading after the cursor advanced

Found during real-app usage. `network_list` LIVE mode is **incremental**: each call advances a cursor and returns only requests newer than the last call. But when an incremental call came back empty, the summary said **"No HTTP captured yet"** even when the session already held requests, so it read as "no traffic" when there was plenty (it cost the agent extra `hot restart` / re-drive cycles chasing phantom-missing traffic).

- The summary now distinguishes the cases: **"No NEW HTTP since your last call ... pass since:0 to re-scan everything captured, or use network_summarize"** vs the genuine **"No HTTP captured yet"** (cursor never advanced) vs **"N scanned, 0 matched filters."**
- When an empty incremental read happens, `nextSteps` now **leads with `network_list since:0`** so the agent surfaces the already-captured requests instead of concluding there is no traffic.
- Logic extracted to a pure `liveListSummary(...)` with unit coverage for every case.

This is a context-efficiency win as much as a UX one: the old wording sent agents down a "there's no traffic" dead end when the data was one `since:0` away.

## [0.8.10] — 2026-06-12

### Added — hot-restart auto-migration (#16)

A background watcher now keeps a session id **stable across a hot restart for any attached app**, without the agent calling `network_attach reattach:true` by hand. When an attached app's VM service URI changes (restart rotates it), the watcher reattaches the same session id to the new URI, repoints the DB row, restarts capture, and drops the stale session, so captures from before and after the restart stay in one session.

Safe by construction: a session migrates only when its own URI has gone away **and** exactly one live URI serves the same logical app identity (`package@device`). Zero or multiple candidates are skipped, never guessed, so a session is never moved onto the wrong app. The auto-attach watcher cooperates: it no longer fresh-attaches a URI that is a restart of an already-tracked app, leaving the migration to this watcher.

This builds on the 0.8.2 `reattach:true` MVP (which stays as the manual path) and reuses its tested migration machinery; the new piece only decides *when* to migrate.

**First-class + agent-visible.** A restart isn't a silent stderr line. Each migration logs `hot restart #N for session <id>` and, more importantly, `network_status.attached[]` now carries `reattachCount` (how many restarts this session has survived, carried across migrations), `lastReattachAtMs`, and `previousVmServiceUri`. So when the agent reads `network_status`, it can see that the captures it's about to read span a restart and didn't reset under it.

- On by default. Opt out with `FLUTTER_NETWORK_MCP_NO_AUTO_MIGRATE=true`.
- Poll interval: `FLUTTER_NETWORK_MCP_MIGRATE_POLL_MS` (1000-60000, default 5000). The tick early-returns when nothing is attached, so it is cheap when idle.

## [0.8.9] — 2026-06-12

### Added — `session_configure` sticky default filters (#18)

A new always-on `session_configure` tool (the 40th) sets **process-wide default filters** that `logs_tail` and `network_list` inherit whenever you omit the matching argument. Set "only `[EventTracker]` logs at level ≥ 1000" or "only 4xx/5xx HTTP" once, then read without repeating it:

```
session_configure levelMin:1000 messageContains:["[EventTracker]"] statusMin:400
logs_tail            # inherits levelMin + messageContains
network_list         # inherits statusMin
logs_tail levelMin:0 # an arg you pass still wins for that call
```

- Inherited filters show up in each read's filter summary, so it's clear what's applied.
- Pass a field to set it, pass it as `null` to unset just that field, `clear:true` to reset all, no args to view current.
- In-memory only; resets on server restart. This is the "sticky filters" item from #18 (live-tail there remains a non-goal).

## [0.8.8] — 2026-06-12

### Added — `logs_tail` `messageContains` list form (#15)

`messageContains` now accepts a **list of tags, OR-matched**, in addition to a single string: `logs_tail messageContains:["EventTracker","KycTier"]` returns logs matching either tag in one call, instead of one request per tag. A bare string still works. Applied server-side in both the live ring buffer and the history (`session_open`) path, so it cuts response size before it reaches the agent. This completes the remaining item on #15 (the single-string filter shipped in 0.8.1).

## [0.8.7] — 2026-06-12

Issue-triage round: a `session_list` identity fix (#27) and a more useful issue template.

### Fixed — `session_list` app identity (#27)

`session_list` could mislead multi-app developers: its only identity filter was `projectPath`, which is just the working directory at attach time. Several apps launched from the same parent dir share that directory, so filtering for one app silently returned another's sessions (the reporter burned ~5 tool calls chasing the wrong app).

- New **`appNameContains`** filter (case-insensitive substring on the DTD app identity), the reliable way to scope to one app. Works alongside `projectPath` (AND).
- `projectPath`'s description now states plainly it is the cwd at attach, not app identity, and points at `appNameContains`.
- When a result set holds more distinct apps than directories, the response carries a **warning** naming the apps and a `nextSteps` hint to re-filter by `appNameContains`, so the trap surfaces itself.

No schema change: the `app_name` column already existed and was already surfaced; this adds the missing filter + guard rails.

### Changed — issue templates ask for the plugin version

Reporters kept omitting which version they were on (it lived only in the collapsible *Optional* block), forcing us to guess whether a bug was already fixed. The `flutter_network_mcp` version is now a **required** field in the bug-report Quick section, and a field in the UX-friction template.

## [0.8.6] — 2026-06-12

Tool-usage analytics, **Phase 3: ship** (issue #79). The local `tool_events` capture from 0.8.4 and the aggregates from 0.8.5 become a periodic, privacy-safe rollup the maintainer can actually receive, under the same audit pact as crash telemetry.

### Added — usage-rollup shipping

A rollup folds every event since a stored high-watermark into one aggregate: per-tool counts, outcome rates (`ok` / `error` / `empty`), p50/p95 latency, average result size, and the tool-to-next-tool transition graph (the same shape `usage_stats` returns). **Raw events never leave the machine; only the aggregate does.** No URLs, hosts, bodies, log text, arg values, or raw correlation ids are ever in the payload.

Same trust model as crash telemetry:

- **Audit log first.** The exact rollup JSON is appended to the hash-chained `telemetry-audit.log` before any network attempt, so `flutter_network_mcp audit show` shows precisely what left (or would have left) the machine.
- **POST only when configured.** The binary still ships with an empty collector endpoint (Path B), so this is **audit-log-only today** and flips to live sending when the collector URL is baked in, exactly as crash telemetry does.
- **Idempotent.** A tiny `usage-ship-state.json` records the last shipped `tool_events.id`, so re-running never double-counts. The rollup carries the same HMAC `machineHash` as crash telemetry, so the collector can attribute both to one install without learning anything identifying.

### Added — triggers

- **Startup auto-ship.** Fire-and-forget on server start, daily-gated (one rollup per day across MCP-host restarts), never blocks the handshake, never throws.
- **`flutter_network_mcp usage ship`** — explicit ship; `--dry-run` prints the rollup without writing or sending it, `--json` emits the structured result.

### Opt-out

Unchanged: `FLUTTER_NETWORK_MCP_NO_USAGE=true` (usage only) or `FLUTTER_NETWORK_MCP_NO_TELEMETRY=true` (everything). With either set, no rollup is built, recorded, or sent.

### Internal

The machine-identity + host-descriptor helpers shared by both reporters now live in one place (`telemetry_env.dart`), so `machineHash` is guaranteed byte-for-byte identical across crash and usage payloads (cross-payload dedupe depends on it). No schema change: the watermark is a state file, so the DB stays at v7.

## [0.8.5] — 2026-06-12

Tool-usage analytics, **Phase 2: insights** (issue #79). The `tool_events` capture from 0.8.4 becomes readable from inside an agent turn.

### Added — `usage_stats` tool (the 39th)

Aggregate view of how agents use this MCP, computed from the local usage capture:

- **Per tool:** call count, outcome breakdown (`ok` / `error` / `empty`), error + empty rates, p50/p95 latency, average result size.
- **Transition graph:** the busiest tool→next-tool pairs, counted only between consecutive calls *within a turn* (grouped by the usage correlation id; never bridging the idle-gap boundary). This surfaces the playbook agents actually follow versus the documented one.
- `sinceMs` window (relative ms; omit for all history) and `topTransitions` (default 15).

Always-on, read-only, process-wide (not session-scoped). Reflects only what was captured, so it returns empty when usage capture is opted out. Pairs with the `flutter_network_mcp usage --show` CLI for the raw events behind the aggregates.

### Deferred

`nextSteps` adoption (did the agent's next call match a hint we emitted?) needs the *suggested* next-tools recorded per event, which Phase 1 doesn't store. Deferred to a later phase that adds that field. Phase 3 still ships aggregate rollups to the collector under the audit pact, once it's live.

## [0.8.4] — 2026-06-12

Tool-usage analytics, **Phase 1: capture only** (issue #79). A local, privacy-safe record of which tools agents call, so the project can build the right features from real usage. Nothing is shipped anywhere in this phase.

### Added — usage capture (schema v7)

One instrumentation chokepoint wraps tool registration, so all 38 tools are measured with zero per-tool changes. Each call records to a new `tool_events` table:

- `tool` name, `tsMs`
- `correlationId` — gap-based "turn" grouping (a new id after `FLUTTER_NETWORK_MCP_USAGE_GAP_MS`, default 60s, of inactivity; MCP carries no conversation id, so this is the proxy)
- `outcome` — `ok` / `error` / `empty` (`empty` is a best-effort `count:0` heuristic, refined in Phase 2)
- `argKeys` — the parameter NAMES passed, **never their values**
- `durationMs`, `resultBytes`

**Privacy by construction:** no URLs, hosts, bodies, log text, or arg values ever touch it. Recording is wrapped so a failure can never break the tool call it measures.

### Added — `flutter_network_mcp usage` subcommand

The transparency surface (mirrors `audit show`): see exactly what's stored.

```bash
flutter_network_mcp usage              # per-tool summary + outcome breakdown
flutter_network_mcp usage --show       # recent raw events
flutter_network_mcp usage --since 7d   # window filter
flutter_network_mcp usage --json       # machine-readable
```

### Opt-out

On by default. `FLUTTER_NETWORK_MCP_NO_USAGE=true` disables usage capture only; the existing `FLUTTER_NETWORK_MCP_NO_TELEMETRY=true` disables usage **and** crash telemetry.

### Roadmap

- **Phase 2:** a `usage_stats` tool — per-tool counts, error/empty rates, p50/p95 latency, the tool→next-tool transition graph, `nextSteps` adoption.
- **Phase 3:** ship aggregate rollups (histograms, not raw rows) to the collector under the existing hash-chained audit pact, once it's live.

### Schema

- **v7:** new `tool_events` table + indexes. Additive migration; no existing data touched.

## [0.8.3] — 2026-06-11

Interactive-debugging wishlist (issue #18) plus the positive-feedback acknowledgement (#19). Closes out the dogfounding-round issue set (#13–#21).

### Added — `correlate_at` (log↔network correlation)

The 38th tool. Given an anchor timestamp (usually a log line's `timestampMs`), returns the log records AND HTTP requests within `±windowMs`, each tagged with a signed `deltaMs` and sorted nearest-first:

```
correlate_at tsMs:1780462000000 windowMs:200
→ { logs:[{deltaMs:-30, message:"[EventTracker] aeon_transaction_started"}],
    requests:[{deltaMs:45, method:"POST", url:".../aeon/transaction", statusCode:200}],
    summary:"1 log(s) + 1 request(s) ... Nearest: POST .../aeon/transaction (+45ms)." }
```

Answers "which request fired closest to this log line?" in one call instead of eyeballing two listings. Reads persisted data (live logs + HTTP both land in the DB), so it works live or after `session_open`; live captures lag ~2s. Available whenever the `http` or `logs` capability is on; returns only the enabled sides (`disabledSides` lists any omitted). Optional `isolateId` scoping. Distinct from `network_correlate`, which matches requests across sessions by shared content rather than by time.

### #19 — positive feedback acknowledged

The behaviours the reporter called out as working well (`nextSteps` on every response, `pendingAlerts.count` baked in, the overflow→file+jq escape hatch, replay/diff discoverability, transparent multi-attach) are intentional and stay. Noted here so the signal isn't lost.

### Deferred (not shipped here)

From #18's wishlist: **live-tail subscription** stays a documented non-goal (MCP has no server-initiated push; polling via `alerts_drain` / `logs_tail` is the model). **Sticky per-session filters** (`session_open defaultFilters`) are deferred — they touch multiple read tools and a per-session config store, and the reporter noted none of the three were individually critical. Re-promote if it comes up again.

## [0.8.2] — 2026-06-11

Hot-restart session continuity (issue #16). Interactive debugging means hot-restarting every ~30 seconds; each restart rotated the VM service URI, spawned a brand-new `sessionId`, and left the dead session listed as attached. Agents burned turns re-attaching instead of debugging.

### Added — `network_attach reattach:true`

Recognises the same logical app across restarts and keeps one stable `sessionId`.

```
network_attach appNameContains:"iPhone 16 Pro" reattach:true
→ { attached:true, reattached:true, liveSessionId:14,
    previousVmServiceUri:"ws://old/ws" }
```

- **Logical identity** is `package + device`, parsed from the DTD app name (`"Kind: Flutter - Device: iPhone 16 Pro - Package: roqquapp"` → `roqquapp@iphone 16 pro`). `iPhone 16 Pro` and `iPhone 16` stay distinct; the same app on the same device across restarts collapses to one identity.
- On a match, the existing `sessions` row is **repointed** at the new VM URI / isolate (so captures before and after the restart share one session id), and the stale session's resources are torn down and dropped from `network_status.attached`.
- No-op when no prior session matches — behaves as a normal attach, so passing `reattach:true` is always safe.
- `network_status.attached[]` gains `lastReattachAtMs` when a session was carried across a restart.

This is the MVP that covers the ~90% case (the agent calls one tool instead of: notice URI changed → look up new URI → detach stale → re-attach). Fully automatic migration (no flag) is a future follow-up.

## [0.8.1] — 2026-06-11

Quick wins from the dogfooding round (issues #15, #21, #20). Small, high-value, no new tools.

### Added — `logs_tail messageContains` filter (#15)

`logs_tail` only filtered by `loggerContains`, which is useless when the app's logs carry an empty logger name (common). Agents were pulling `limit:500` and grepping out-of-band, repeatedly blowing the host's output cap.

New `messageContains` parameter does a case-insensitive substring match on the message body itself, applied server-side (DB `LIKE` for history, in-memory for live) so it cuts response size before it reaches the agent:

```
logs_tail messageContains:"[EventTracker]"
```

### Added — configurable log ring buffer (#21)

The 500-record ring buffer rotated too fast for chatty apps, dropping events before they could be read.

- Env var `FLUTTER_NETWORK_MCP_LOG_BUFFER` (alias `..._LOG_BUFFER_SIZE`), clamped 50–10000, default 500.
- Per-session override: `network_attach logBufferSize:2000` for one chatty session without affecting others.
- `network_status.attached[]` now surfaces `logBufferUsed` + `logBufferCapacity` so the agent can reason about rotation proactively.
- The "near capacity" warning + `nextSteps` hint now read the *real* configured capacity (were hardcoded to `/ 500`) and fire at 80% full.

### Changed — agent feedback instructions are now actionable (#20)

The server `instructions` field said "report any issue proactively" but gave no concrete triggers, so agents rarely did. Rewritten with explicit triggers (user voices friction / a tool errors and you work around it / a debugging session ends), a one-line offer script, and rules (ask before filing, once per conversation, concrete repro only). Routed through the `report_issue` tool (0.7.2). The auto `agent-filed` label was already shipped in 0.7.2.

### Housekeeping

- Removed em dashes that slipped into the 0.8.0 Dart sources, per project convention.

## [0.8.0] — 2026-06-11

Trust-breaking bug fixes from the first round of real dogfooding (issues #13, #14, #17). These three made the tool give wrong or empty answers without saying so, which is worse than failing loudly.

### Fixed — response bodies stranded forever (#13)

`network_get` returned `response: null` indefinitely for chunked / gzip responses, and `network_search` could not see their payloads, even after the app had clearly received and parsed the body.

**Root cause:** the capture writer only backfilled bodies (and the FTS search index) for requests with `end_us` set. The dart:io HTTP profiler never marks chunked/gzip-streamed responses response-complete, so `end_us` stayed NULL and those requests were skipped permanently.

**Fix:** the backfill gate now also picks up response-incomplete requests once they're older than a short grace window, capped by a new `body_fetch_attempts` counter (schema **v6**) so genuinely body-less or transport-invisible requests stop being re-polled instead of looping forever. The misleading `network_get` warning ("bodies may grow on a subsequent call") is replaced with an accurate one that tells the agent when a response is terminally unreachable via vm_service and to fall back to `logs_tail`.

> Note: responses from transports that bypass `dart:io HttpClient` (custom `HttpClientAdapter`, native HTTP) remain invisible at the vm_service layer — that's the realtime-capture gap tracked for the 0.9.x companion package. This fix restores everything the profiler *does* capture.

### Fixed — `network_attach appNameContains` failed across DTDs (#14)

`network_attach appNameContains:"iPhone 16 Pro"` returned `"DTD is up but reports no connected apps yet."` even when `network_status.knownApps` listed exactly that app.

**Root cause:** `network_status` aggregates apps across every discovered DTD (each `flutter run` spawns its own), but attach resolved the name filter against only the default DTD. An app owned by another DTD was invisible to the matcher.

**Fix:** when `appNameContains` is given without an explicit `dtdUri`, attach now resolves across **all** discovered DTDs (same probe that powers `knownApps`) and connects to the owning DTD. Error messages are accurate per case: nothing running, no name match (with the visible-app list), or ambiguous match (with candidates) — no more "no apps yet" when a filter simply missed.

### Changed — structured capability health on attach + status (#17)

Partial degradation (e.g. socket profiling failing to enable) was only mentioned in a `warnings` string that agents tend to scroll past, then `socket_*` tools returned empty arrays.

**Fix:** `network_attach` and each `network_status.attached[]` entry now carry a structured block:

```jsonc
"capabilities": { "http": "ok", "socket": "unavailable", "logs": "ok" },
"degraded": ["socket"]
```

`disabled` (off in config) is distinguished from `unavailable` (enabled but failed to start) — only the latter counts as degraded. This is per-session runtime health, distinct from the top-level `capabilities` field that reports globally-enabled categories. (`socket_*` already return a real error rather than empty when their capability is unavailable, since 0.7.x.)

### Schema

- **v6:** `http_requests.body_fetch_attempts` column (backfill retry cap). Migration is additive; existing rows default to 0 and re-enter the backfill path on the next tick.

## [0.7.4] — 2026-06-04

Onboarding + persistence. Closes the `claude mcp remove + claude mcp add --auto-attach=...` cycle the user flagged back in 0.6.2 and replaces the multi-step "first launch" dance with one command.

### Added — writable auto-attach config

New persistent file `<data-dir>/auto-attach.json`:

```jsonc
{
  "allowed": ["sanga_mobile", "sanga_driver"],
  "denied": ["iPhone 7"],
  "writtenAtMs": 1780462000000
}
```

**Resolution order at next launch:**

1. Read `<data-dir>/auto-attach.json` as the BASE.
2. Apply `FLUTTER_NETWORK_MCP_AUTO_ATTACH` / `FLUTTER_NETWORK_MCP_AUTO_ATTACH_DENY` env vars (if set) as overrides.
3. Apply `--auto-attach` / `--auto-attach-deny` CLI flags (if set) as final overrides.

The file is the persistent default; env vars + flags stay as per-launch overrides.

### Added — `auto_attach_config` tool

New always-on lifecycle tool. Single tool with `action` argument:

```
auto_attach_config action:"add" app:"sanga_mobile"
  → writes the file, updates in-memory config, returns persisted:bool
```

Actions: `list` (default — read current state), `add`, `remove`, `clear`. The `autoAttachSuggestion` field on `network_attach` (shipped in 0.6.2) gives the user-friendly path; this tool lets the agent persist the user's confirmation directly without asking them to edit shell rc.

**The agent must ASK THE USER first.** The doc + the upstream `autoAttachSuggestion.agentAction` both emphasize that this tool is gated on explicit user confirmation.

### Added — `setup` wizard subcommand

`flutter_network_mcp setup` is an interactive first-run wizard. Six steps, each opt-in via y/N prompt:

1. Welcome + overview.
2. Detect Claude Code MCP host config (`~/.claude.json` or project-level `.mcp.json`); offer to scaffold the `flutter-network` entry.
3. List currently-running DTDs via the 0.6.2 discovery directory; offer auto-attach for each by inferred package name.
4. Offer `install` (AOT compile) for sub-100 ms startup.
5. Summary + "restart your MCP host" hint.

Each filesystem write is confirmed before it happens. The wizard never silently changes anything. Empty enter = step's default (usually yes); EOF (non-interactive) skips every step defensively.

**Scope: Claude Code only** per the maintainer setup decision. Cursor / Windsurf / Zed are listed in the wizard output as "roadmap; add manually for now" so users know the limitation up front.

### Notes

- Tool count: 36 → **37** (`auto_attach_config` added under lifecycle).
- Schema unchanged from 0.6.3 (v5).
- `setup` is a bin/ subcommand (alongside `install` / `update` / `audit`), not an MCP tool.
- 6 new unit tests on `AutoAttachConfig` file persistence (round-trip, malformed JSON resilience, type-resilience, empty-string filter). Total: 109.

## [0.7.3] — 2026-06-04

Smarter signals + continuity. Two changes that each take signal the MCP already has and use it more intelligently: baseline-relative anomaly detection replaces a noise-prone static threshold, and session continuation makes the MCP remember what you were debugging across host restarts.

### Added — baseline-relative anomaly alerts

Static thresholds (`http_slow` at fixed 3000 ms) miss real regressions on endpoints that are normally either much faster or much slower. A login endpoint that's normally 200 ms going to 1500 ms is the signal; the same 1500 ms on a CSV-export endpoint that's usually 5000 ms is just normal traffic.

New `AnomalyDetector` singleton with a 30 s polling tick. For each attached session per tick:

1. Pull HTTP rows from last 5 min 30 s.
2. Split into current (last 30 s) + baseline (preceding 5 min).
3. Group by `(method, host, pathTemplate)` — same normalization as `network_summarize`.
4. For each endpoint with ≥ 10 requests in BOTH windows:
   - **Latency**: fire `http_anomaly` (warning) when current p95 > **2× baseline p95**.
   - **Error rate**: fire `http_anomaly_errors` (error) when current error rate > **5× baseline AND above 10% absolute floor**.

The floor prevents noise on near-zero baselines (`0% → 0.1%` is infinite multiplier); the multiplier prevents noise on already-high baselines.

Alerts dedupe through the 0.6.3 signature pipeline — a burst of 50 anomaly events on the same endpoint collapses to one row with `occurrenceCount` rolling up.

**Lifecycle**: singleton, lazily started on first attach, stopped when registry hits zero. No background work while detached.

**Disable**: `AlertRules.anomalyEnabled` exposed alongside the existing rule toggles. `alerts_config rules.http_anomaly:false` turns it off. Default: true.

New alert kinds: `http_anomaly` (warning) + `http_anomaly_errors` (error). Both new to the `alert_detector`'s kind taxonomy. The existing `http_slow` static rule stays — anomaly detection complements it.

### Added — session continuation memory

Every Claude Code reload, machine reboot, or MCP-host crash today loses the attachment state. The agent's first `network_status` comes back empty, the user re-types "attach to sanga_mobile", etc. This release makes the next launch say "you were on sanga_mobile 47 min ago, here's the reattach command" — zero friction.

New `<data-dir>/last-session.json`:

```jsonc
{
  "writtenAtMs": 1780462000000,
  "attachments": [
    {
      "vmServiceUri": "ws://127.0.0.1:54450/abc=",
      "appName": "sanga_mobile",
      "attachedAtMs": 1780461000000
    }
  ]
}
```

Multi-attach friendly — all currently-attached sessions get recorded. Written on every successful attach + detach; cleared when nothing is attached.

`network_status` surfaces a `continuation` block at the top level (when `attachedCount == 0` and a record exists), and adds a `nextStep` of the form:

```
network_attach vmServiceUri:"ws://..." — reattach to sanga_mobile (~47m ago); previous attachment recorded by 0.7.3 continuation
```

Explicit detach removes the continuation so a clean teardown doesn't haunt the next session.

### Notes

- Tool count unchanged from 0.7.2 (still 36).
- Schema unchanged from 0.6.3 (v5).
- 13 new unit tests (4 session continuation round-trip + 9 anomaly detector via `detectAnomalies` pure function). Total: 103.

## [0.7.2] — 2026-06-04

Maintainer loop + project memory. Two changes that each take a manual step the user used to do — composing a bug report from scratch, and re-discovering a recurring bug they fixed weeks ago — and convert it into a single tool call or a free side-effect of an alert drain.

### Added — `report_issue` tool

New always-on lifecycle tool. Lets agents file GitHub issues against this MCP from inside a turn:

```
> report_issue type:"bug" title:"network_summarize p95 is null when only 1 request"
   body:"network_summarize with one captured request returns p95LatencyMs..."
< {filed: true, url: "https://github.com/Lukas-io/flutter_network_mcp/issues/47", ...}
```

Two types — `bug` (code issue, wrong output, crash) and `ux` (works but feels awkward / confusing / slow / unclear). When `gh` CLI is installed (and `auto:true`, the default), shells `gh issue create --repo Lukas-io/flutter_network_mcp --title ... --body ... --label ...`. Otherwise returns a GitHub deep-link URL with `title=`, `body=`, `labels=` pre-filled in the query string — the user opens it in a browser and the new-issue form arrives ready to submit.

Labels:

- `bug` → `[bug, agent-filed]`
- `ux` → `[ux-friction, agent-filed]`

The `agent-filed` label lets the maintainer triage agent-vs-human reports at a glance.

**Path-redacted by default.** Title + body run through the same redactor that scrubs telemetry stack frames (`<project:X>/...`, `<home>/...`, Windows equivalents). Defense-in-depth — agents should still avoid putting paths in issue text.

The existing `instructions` field already directed agents to file proactively; this tool removes the "copy-paste body into GitHub" friction from that flow.

### Added — cross-session pattern memory

When `alerts_drain` (or `alerts_peek`) emits a row with a signature, the response now includes `priorOccurrences` listing past sessions where the same signature fired:

```jsonc
{
  "id": 42,
  "kind": "flutter_error",
  "title": "RenderFlex overflowed by 14 pixels on the right",
  "signature": "a3f7c8d219b4",
  "occurrenceCount": 200,
  "priorOccurrences": [
    {
      "sessionId": 14,
      "startedAtMs": 1780462000000,
      "appName": "sanga_mobile",
      "note": "fixed by adding Expanded — lib/view/widgets/cart.dart"
    }
  ]
}
```

The agent now sees "you hit this RenderFlex overflow 3 days ago and your note says it was a missing Expanded" — for free, on every drain. Per-project debugging conversations become a knowledge artifact instead of evaporating.

**Implementation:** new `CapturesDao.priorOccurrencesForSignature` query joins `alerts` and `sessions`, groups by session, orders newest-first, excludes the current session. Default limit 3. The existing 0.6.3 signature is the join key — no new schema, no migration.

### Notes

- Tool count: 35 → **36** (`report_issue` added under lifecycle).
- Schema unchanged from 0.6.3 (v5).
- 14 new unit tests (7 prior-occurrences DAO + 7 report_issue URL composition). Total: 90.
- The `gh` CLI path isn't unit-tested (would need process mocking); the always-available paste-ready fallback has full coverage.

## [0.7.1] — 2026-06-04

Crash telemetry. Default-on with a tamper-evident local audit log, opt-out via `FLUTTER_NETWORK_MCP_NO_TELEMETRY=true`.

**The trust pact.** More signal for the maintainer (silent crashes become signal we can act on within days instead of dying unreported), in exchange for full transparency to the user about what we know — every byte sent off-machine is also written to a hash-chained local log the user can verify or inspect at any time.

### Added — runZonedGuarded reports crashes

The top-level zone guard (in place since 0.6.2) now also calls `TelemetryReporter.maybeReport` on uncaught errors. The reporter:

1. Skips entirely when `FLUTTER_NETWORK_MCP_NO_TELEMETRY=true`.
2. Builds an anonymized payload (schema below).
3. Appends a tamper-evident audit log entry FIRST.
4. POSTs the same payload to a maintainer-controlled collector with a 3 s deadline (when configured — see "Collector status" below).

Fire-and-forget. Never blocks shutdown. All errors swallowed.

### Added — tamper-evident audit log

`<data-dir>/telemetry-audit.log`. One line per report:

```
<ts>|<prev_hash>|<payload_b64>|<this_hash>
```

`this_hash = sha256(ts + prev_hash + payload_b64)`. `prev_hash` links each line to the previous (64 zeros for the first). The chain catches any silent edit OR removal — three scenarios verified by unit tests:

- Payload edit: `this_hash` recomputation fails on that line.
- Line removal: the next line's `prev_hash` no longer matches the chain.
- Malformed line: parsed as null at its index.

**Tamper-EVIDENT, not tamper-PROOF.** The user owns the file. Same trust model as `git log`.

### Added — `audit` subcommand

```
flutter_network_mcp audit verify
flutter_network_mcp audit show
flutter_network_mcp audit show --since 7d
flutter_network_mcp audit show --signature <sig>
```

`verify` walks the chain and prints `N entries, chain intact` + first/last timestamps OR `chain broken at entry K (reason)`. Exit code 70 on broken chain so CI scripts can detect tampering.

`show` decodes the payloads and pretty-prints each entry. `--since` filters by relative duration (`Nd | Nh | Nm`). `--signature` filters to the 12-char dedupe key in the payload.

### Payload schema

```jsonc
{
  "version": "0.7.1",
  "commit": "4aa550c...",        // 12 hex chars
  "isAot": true,
  "os": "macos 14.6",
  "dart": "3.5.0",
  "errorClass": "StateError",
  "errorMessage": "DTD is not connected.",
  "stackHead": [
    "#0 DtdClient._requireConnected (package:flutter_network_mcp/src/vm/dtd_client.dart:36)",
    "..."
  ],
  "signature": "a3f7c8d219b4",    // sha256(errorClass + top-3-frames)[:12]
  "machineHash": "f1a823bc91...", // HMAC(dataDir, kPublicSalt)[:24]
  "reportedAt": "2026-06-04T12:34:56Z"
}
```

### NOT in the payload

The path redactor strips before anything is recorded:

- `$HOME`, `cwd`, the target Flutter project path, any `/Users/<name>/…` or `C:\Users\<name>\…`
- The target app's `vmServiceUri` / DTD URI / connection token
- Any captured HTTP body, header, URL
- Env-var contents (only `FLUTTER_NETWORK_MCP_NO_TELEMETRY` presence is read, never logged)
- `captures.db` row contents

14 fuzz-corpus tests in `test/telemetry/path_redactor_test.dart` verify the redaction across POSIX + Windows shapes including the "anti-leak" check (no username string appears anywhere in the payload).

### Collector status — path B (local-only) for 0.7.1

`kCollectorEndpoint` is empty in this release. The binary writes the audit log but doesn't POST. The trust pact's LOCAL half works today; the central signal layer ships in 0.7.1.x once the Cloudflare deploy lands. See `docs/MAINTAINER_SETUP.md` path A for the deploy steps.

This split was deliberate: it lets us ship the user-facing transparency (audit log + `audit verify` + opt-out) without waiting on infrastructure deploy. When the collector URL is ready, a small follow-up patch flips the constant and the existing payload + opt-out + audit log all carry over.

### Opt-out

```bash
export FLUTTER_NETWORK_MCP_NO_TELEMETRY=true
```

Set this and the telemetry code never runs. No audit write, no network attempt. Recommended for SOC 2 / regulated environments.

### Notes

- 30 new unit tests (path redactor 14 + audit log 8 + payload builder 8). Total: 76 tests, all passing.
- `lib/src/util/data_dir.dart` refactored out of `install.dart` so install + audit log + DB all agree on the user's state directory.
- Tool count + schema unchanged from 0.7.0 — telemetry is bin/runtime infrastructure, not an MCP tool.

## [0.7.0] — 2026-06-04

Context economy. Two changes that each cut the bytes a typical
debugging turn burns in the agent's context window, without
losing actionable signal.

### Added — `network_summarize` tool

New `http` capability tool. Returns one digest row per
`(method, host, pathTemplate)` bucket over a time window:

```jsonc
> network_summarize sinceMs:600000
< {
    count: 5,
    endpoints: [
      {endpoint:"GET api.example.com/api/users/N", count:198,
       statusDist:{"200":187,"404":10,"500":1},
       p50LatencyMs:145, p95LatencyMs:820, errorRate:0.056},
      ...
    ]
  }
```

Path templates collapse dynamic ids via the new
`lib/src/util/path_template.dart` helper: pure-integer segments → `N`,
8+ hex chars → `H`, full 8-4-4-4-12 UUID → `UUID`. Mixed-content
segments (`abc-123`, `v2-final`) stay verbatim. Query strings +
fragments stripped (endpoint identity is routing-level, not
parameter-level).

The "what's wrong with my API" first call. Doubles as a shape
overview of the captured session in ~500 bytes — typically far
cheaper than `network_list + manual bucketing`.

Inputs: `sinceMs` (default 1 h, 0 = entire session), `hostContains`,
`limit` (default 50, hard cap 200), `minCount` (default 1).

Reads from DB regardless of live/history scope; raw-row cap of 10 000
with `rawRowsCapHit` flag when hit.

### Added — semantic body truncation

`decodeBody` (used by `network_get`) now content-type-aware truncates:

- **JSON**: arrays past 5 elements collapse to first 5 + marker
  `{"_truncated":"42 more, 5 of 47 shown"}`. String leaves over 200
  chars clip with `…(<n> chars)`. Object keys all preserved (the
  agent wants the SHAPE).
- **HTML**: `<script>` + `<style>` contents stripped, comments
  removed, whitespace collapsed.
- Output hard-capped at the caller's `bodyTruncateBytes` (default
  4 KB) regardless of mode. Fall-through to byte-cap when input
  unparseable or > 256 KB.

Each response carries `truncationMode: "semantic" | "byte" | null`
so the agent can tell what happened. A typical "list of 100 users"
response now lands at ~1 KB with all keys + 5 sample rows visible,
instead of a half-mangled 4 KB byte slice. The agent reads the same
information AND can parse it.

`network_diff`, `network_body`, and `har_exporter` opt out (force
`semantic: false`) — they need byte-exact contracts (line-by-line
diff, byte-range paging, HAR replay).

### Notes

- Tool count: 34 → **35** (`network_summarize` added under HTTP).
- Schema unchanged from 0.6.3 (v5). No migration.
- First time the repo gets a `test/` directory. 46 unit tests across
  `pathTemplate`, `summarizeRequests`, and `truncateJson` /
  `truncateHtml`. `dart test` clean.

## [0.6.3] — 2026-06-04

Alert deduplication by signature. A single Flutter `RenderFlex` overflow on an item that's repeated 200 times in a list used to produce 200 nearly-identical alert rows — the existing `UNIQUE(session_id, kind, source_id)` constraint dedupes the SAME source event but doesn't know that 200 distinct log row ids reflect ONE underlying bug. Same problem for HTTP: 50 5xx responses from different request ids on `/api/users/N` were 50 separate rows. The agent ended up surfacing 200 alerts for what was, semantically, one issue.

0.6.3 groups by SIGNATURE — a stable hash over `kind + normalized title` that's identical across events reflecting the same issue. The agent now sees ONE alert with `occurrenceCount: 200`, not 200 alerts. Severity escalates to the highest seen across the burst.

### Added — `lib/src/alerts/signature.dart`

`computeAlertSignature(kind, title)` returns `sha256(kind + ':' + normalized)[:12]`. Normalization lowercases, redacts `$HOME` / `StudioProjects/<x>/` paths, collapses digit runs to `N`, hex runs (8+ chars) to `H`, whitespace to single spaces. Lossy on purpose — two events that differ only in pixel counts / line numbers / ids collapse into the same signature. Adds `package:crypto` (5 KB, maintained by Google's Dart team).

### Changed — `alerts` schema v4 → v5

Four new nullable columns: `signature`, `occurrence_count` (default 1), `last_seen_ms`, `last_source_id`. New partial unique index `(session_id, signature) WHERE drained=0 AND signature IS NOT NULL` enforces "at most one pending alert per signature per session" without tripping on legacy NULL-signature rows. Existing `UNIQUE(session_id, kind, source_id)` kept as a safety net for the rare duplicate-source-delivery race.

Backfill: legacy rows get `last_seen_ms = ts_ms`; signature stays NULL so they drain through the normal path as before. No data loss; no breaking change to existing 0.6.2 DBs.

### Changed — `insertAlert` is now upsert-by-signature

`captures_db.dart` `insertAlert` gained a required `signature:` arg and a SELECT-then-(UPDATE-or-INSERT) flow:

- If a pending row with the same signature exists for the same session: increment `occurrence_count`, advance `last_seen_ms` + `last_source_id`, bump severity if the new event is more severe (highest-seen wins). Returns `false` (no new row).
- Otherwise: INSERT fresh row at `occurrence_count = 1`. Returns `true`.
- Legacy `UNIQUE` constraint (sqlite extended error 2067) caught and treated as already-handled.

New DAO method `pendingAlertEventCount` returns `SUM(occurrence_count)` for matching pending rows (the raw event count, vs `pendingAlertCount` which returns DISTINCT-row count).

### Changed — `alerts_drain` / `alerts_peek` output shape

Each alert row now carries:

- `occurrenceCount: int` — how many events collapsed into this row
- `firstSeenMs: int` — alias of `tsMs` exposed for clarity
- `lastSeenMs: int` — most recent event ms
- `lastSourceId: string?` — `source_id` of the most recent event (drill into the latest via `network_get`)
- `signature: string?` — 12-char hex grouping key (useful for debugging / cross-referencing)

Legacy rows default `occurrenceCount` to 1 and omit `lastSourceId` / `signature`. `tsMs` and `sourceId` keep their original meaning (first-seen) — agents don't need to migrate.

### Changed — `network_status.alerts` surfaces both counts

```jsonc
"alerts": {
  "pendingTotal": 1,      // distinct signatures — what to branch on
  "pendingEvents": 200,   // sum of occurrence_count — raw volume
  "critical": 0
}
```

`pendingTotal` is the actionable count ("should I drain?"). `pendingEvents` is the noise metric ("there's a burst happening" without flooding the alerts list). Multi-attach `perAttached` block gets `pendingEvents` too.

### Notes

- **Drain resets the counter.** Once an agent has acknowledged a burst, a fresh occurrence of the same signature creates a NEW row at count 1. The `occurrence_count` is "events seen since the last drain," not lifetime.
- **Severity escalation = highest seen.** One critical buried in 199 warnings escalates the row to critical; the agent sees "200 occurrences, critical" and acts on the worst case.
- **Signature is intentionally lossy.** A bug that's "the same except for one detail" SHOULD collapse — the user wants one alert per underlying issue, not 200 variations. Drill into the specifics via `network_get id:"<sourceId>"` (first event) or `<lastSourceId>` (most recent).
- **Per-session scoped.** Two attached sessions producing the same signature each get their own row — no cross-session merging.

## [0.6.2] — 2026-06-03

Zero-config DTD discovery. Before 0.6.2 the typical onboarding flow was: launch `flutter run`, copy the printed `ws://...` URI from the IDE console, paste it into `.mcp.json`, restart Claude Code. Agents working in fresh sessions ended up running `lsof + ps` to find the port and still failed because they couldn't get the security token. 0.6.2 reads the canonical `package:dtd` discovery files directly — token included — so the MCP just works when launched in a project with a live `flutter run`.

### Added — DTD auto-discovery

- **Startup hook** (`bin/flutter_network_mcp.dart`): when neither `--dtd-uri` nor `FLUTTER_NETWORK_MCP_DTD_URI` is set, the server scans the standard `package:dtd` discovery directory and picks the best live candidate. A one-line stderr note names the chosen DTD's pid + workspaceRoot + epoch and points at the override flags.
- **Discovery paths** (per-platform, matches `package:dtd`):

  | Platform | Path |
  |---|---|
  | macOS   | `$HOME/Library/Application Support/dart/dtd` |
  | Linux   | `$XDG_CONFIG_HOME/dart/dtd` (fallback `$HOME/.config/dart/dtd`) |
  | Windows | `%APPDATA%/dart/dtd` |

- **Ranking** (best-first): live process (`kill -0` POSIX / `tasklist` Windows) over dead, `workspaceRoot == cwd` over mismatch over null, newer epoch over older.
- **Defensive 64-file scan cap** so a pathologically-busy discovery dir can't blow the budget. Errors during scan log to stderr and produce an empty list — never throws.

### Added — `network_discover_dtd` tool

New always-on lifecycle tool that exposes the discovery surface to the agent on demand. Inputs: `cwdMatch` (default true), `includeStale` (default false — dead-pid candidates), `limit` (default 5, hard cap 20). Returns per-candidate `wsUri / pid / epochMs / dartVersion / workspaceRoot / ideName / isLive / matchesCwd` plus a `recommended` URI and ranked `nextSteps` pointing at `network_attach`. Use it when:

- Multiple `flutter run` instances are running and startup auto-discovery picked the wrong one.
- A discovery file might be stale (Dart process died uncleanly) — `includeStale:true` to inspect.
- The MCP was launched from outside the project's cwd — `cwdMatch:false` to see every DTD.

### Changed — `network_status` integration

`_suggestNextSteps()` now consults discovery when not attached and no DTD is configured, instead of the old "ask the user for a URI" message. Live cwd-matching candidates surface as `network_attach dtdUri:"<wsUri>"`. Live non-cwd-matching candidates surface as a `network_discover_dtd` suggestion to disambiguate. Empty discovery falls back to the existing "No DTD URI configured" message but now mentions `network_discover_dtd` as the entry point.

### Added — env vars

- `FLUTTER_NETWORK_MCP_AUTO_DISCOVER_DTD` (default enabled; set to `false` to disable). Equivalent to `--no-auto-discover-dtd`.

### Added — `install` and `update` subcommands

`dart pub global activate -s git URL` ships a JIT snapshot wrapper that re-runs `pub get` + recompiles on every spawn (~1–2s cold). The MCP host's JSON-RPC handshake can race the recompile and mark the server "Failed to connect" on first attach, then succeed on the next probe — flickering connection status.

- `flutter_network_mcp install` runs `dart compile exe` and overwrites the JIT wrapper at `~/.pub-cache/bin/flutter_network_mcp` (or platform equivalent) with a native binary. Startup drops to <100ms; no recompile, no flicker. Writes `<data-dir>/.compiled` marker so the `update` subcommand knows to re-AOT.
- `flutter_network_mcp update` re-runs `dart pub global activate -s git https://github.com/Lukas-io/flutter_network_mcp.git` and (if `.compiled` exists) re-runs the AOT compile so the upgrade doesn't silently downgrade you back to the JIT wrapper.
- **JIT-mode detection** at startup via `bool.fromEnvironment('dart.vm.product')` (canonical Dart AOT-vs-JIT check). When running as JIT, one-line stderr nudge points at the install subcommand. Silence with `FLUTTER_NETWORK_MCP_NO_JIT_NUDGE=true`.

### Added — multi-DTD app enumeration

Each `flutter run` spawns its own DTD. Before 0.6.2, the MCP connected to one DTD and only saw the apps registered to THAT DTD. A user with sanga_mobile + sanga_driver + a sample in three `flutter run` terminals saw only ONE in `network_status.knownApps`.

New `lib/src/vm/dtd_probe.dart` enumerates apps across every live DTD on the machine via TRANSIENT `DtdClient` connections — never touches `Session.instance.dtd` or attached session state. Parallel `Future.wait` with a 1.5s per-probe timeout so one hung DTD can't block the others. Result cached for 30s keyed by discovery-key (sorted pid:epoch tuples).

`network_status.knownApps` now lists apps across all DTDs. Each entry carries new `dtdUri` + `workspaceRoot` fields naming the source DTD — the agent can pick the right `dtdUri:` arg for `network_attach` if needed, though direct `vmServiceUri:` works without DTD at all. Existing fields (`name`, `uri`, `exposedUri`) unchanged. Per-DTD probe errors surface in `dtdProbeErrors`.

AutoAttacher uses the same probe so `--auto-attach=sanga_mobile,sanga_driver` works across multiple DTDs — when a matching app is found in a DTD OTHER than the primary, attach happens via `performAttach(vmServiceUri: ...)` (the existing branch that bypasses DTD entirely), so the primary connection is never disturbed.

### Changed — auto-attach first tick

0.6.1's defensive design seeded already-running apps into `_seenUris` on the first tick of `AutoAttacher` WITHOUT attaching them. But 0.6.1 also made the allowlist mandatory — the user has already explicitly named which apps to grab. Skip-on-first-tick meant if sanga_mobile was running before the MCP came up, the agent couldn't see it until a Flutter restart.

The early-return at `auto_attach.dart:206` is dropped. First-tick behaviour now: log the intent (`auto-attach first tick — evaluating N currently-running app(s) against allowlist X`), then fall through to the standard allowlist gate + `performAttach` loop. The existing `_seenUris` de-dupe (post-attach the URI joins the set) prevents double-attach on subsequent ticks. Allowlist + denylist gates unchanged.

### Added — startup version check

`lib/src/update/update_check.dart` runs at most once per UTC day. Fetches `pubspec.yaml` from `master` via raw.githubusercontent.com (no GitHub API rate limits), parses the `version:` line, compares against the embedded `packageVersion`. When newer, one stderr nudge names the upstream version + the `update` subcommand. Uses `dart:io HttpClient` directly (no new dependency). Fire-and-forget from `main()` — never blocks the MCP-host handshake. All errors swallowed silently.

Cache file: `<data-dir>/.update-check` (one-line ISO timestamp; touched on every successful poll). Opt-out: `FLUTTER_NETWORK_MCP_NO_UPDATE_CHECK=true` skips the whole probe.

### Added — env vars

- `FLUTTER_NETWORK_MCP_AUTO_DISCOVER_DTD` (default enabled; set to `false` to disable). Equivalent to `--no-auto-discover-dtd`.
- `FLUTTER_NETWORK_MCP_NO_JIT_NUDGE` (`true` to silence the JIT-mode install nudge).
- `FLUTTER_NETWORK_MCP_NO_UPDATE_CHECK` (`true` to skip the daily version probe entirely).

### Reconfiguring without `mcp remove + add`

README gains a "Reconfiguring without re-registering" section explaining that every CLI flag has an env-var fallback. Edit shell rc, restart your MCP host, new config takes effect — no `claude mcp remove + add` cycle.

### Added — agent-readable `mcp` block in `network_status`

`network_status` responses now carry a top-level `mcp` block with `version`, `commit` (when known), `isAot`, `upgradeCommand`, and (when the daily background check has flagged a newer release) `updateAvailable: { latest, checkedAtMs }`. The agent can read this on every `network_status` call to identify the running build and recommend the upgrade command without scraping stderr.

**Commit SHA bake-in.** `flutter_network_mcp install` resolves the source dir's commit via `git rev-parse HEAD` and passes `-Dflutter_network_mcp_sha=<sha>` to `dart compile exe`. Under JIT, the same constant falls back to a runtime git read against the activated source dir. Both paths cache per process.

**Status file.** `UpdateCheck.maybeCheck` now writes `<data-dir>/.update-status.json` alongside the existing `.update-check` cache so `network_status` can surface the result without re-hitting the network.

### Added — `autoAttachSuggestion` on `network_attach`

After a successful attach, the response includes an `autoAttachSuggestion` block when the attached app isn't already covered by the `FLUTTER_NETWORK_MCP_AUTO_ATTACH` allowlist. The block carries:

- `appName` / `pattern` (extracted token — "sanga_mobile" from "Flutter - iPhone 17 - Package: sanga_mobile")
- `currentAllowlist`, `enabled`
- `suggestedShellLine` (paste-ready `export ...`)
- `agentAction` (explicit instruction to ASK THE USER before editing anything)

The agent reads `agentAction`, asks the user whether to add the app to auto-attach for future sessions, and only edits the shell rc on confirmation. Already-allowlisted apps get no hint (no nag). The goal: turn one-off attaches into durable auto-attach config without making the user type `claude mcp remove + add`.

New `lib/src/config/auto_attach_config.dart` publishes the resolved allowlist + denylist as a process-lifetime singleton so non-`bin/` tools can read the live config without re-parsing.

### Notes — crash telemetry TODO

User-asked TODO marker for a future opt-IN crash-telemetry channel (so bugs come back to the maintainer without a GitHub roundtrip). NOT IMPLEMENTED in 0.6.2. New `docs/CRASH_REPORTING.md` sketches the design — opt-IN env var, anonymized payload (version, OS, error class, stack head with paths redacted), no PII / source paths, local audit trail, single maintainer-controlled collector endpoint TBD. Marker comment in `bin/flutter_network_mcp.dart` points at the design doc.

### Notes

- Live-verified on macOS against 4 currently-running DTDs (sanga_mobile, sanga_driver, two dart-sdk Android Studio sessions). The Linux + Windows path branches were reviewed but not runtime-tested in this round.
- No security gap: the discovery files are written by `package:dtd` itself and are protected by per-user filesystem permissions. The MCP can only see what the user can see.
- Tool count: 33 → **34** (`network_discover_dtd` added under Lifecycle). Tool surface unchanged in the multi-DTD work — only `knownApps` shape gained additive fields.

## [0.6.1] — 2026-05-28

A security + reliability follow-up to 0.6.0. Closes a real auto-attach exposure that 0.6.0's audit caught after the merge.

### Security — auto-attach allowlist (mandatory) — **BREAKING vs. 0.6.0**

0.6.0 shipped `--auto-attach` as a boolean that captured every Flutter app DTD discovered after server start. A developer running `flutter run -t lib/main_prod.dart` against a target wired to staging-with-production-tokens (a common shortcut) would have prod traffic captured to disk without explicit consent.

**Fix:**

- `--auto-attach` is now an option taking a comma-separated allowlist of case-insensitive substring patterns matched against the app name DTD reports: `--auto-attach=sanga_mobile,sanga_driver`.
- **There is no boolean form.** To enable auto-attach you MUST specify which apps it's allowed to grab. Empty / absent disables.
- `FLUTTER_NETWORK_MCP_AUTO_ATTACH=app1,app2` follows the same semantics (env var changed from `true|1`).
- Non-matching apps log a one-line stderr note and are added to the known-URI set so the watcher doesn't retry every tick (acts as both rate-limit and audit trail).
- `AutoAttacher`'s constructor enforces this with an assertion — the class is impossible to instantiate without a non-empty allowlist.

**Optional denylist** — `--auto-attach-deny=Pixel 7,Android emulator` (or env var `FLUTTER_NETWORK_MCP_AUTO_ATTACH_DENY=...`) excludes specific apps/devices even when the allowlist would otherwise admit them. Useful for cases where the allowlist is a broad package name (e.g. `sanga_mobile`) but a particular device or form factor should be skipped. Same case-insensitive substring matching as the allowlist. Deny wins over allow. DTD reports names like `Flutter - iPhone 17 - Package: sanga_mobile`, so substring patterns can target either the package or the device.

**Migration from 0.6.0:** if you launched the server with `--auto-attach` (bool form, no value) in 0.6.0, change it to `--auto-attach=<app substring,...>`. Same for the env var. Without the value, the watcher silently stays off — no surprise grabbing.

### Reliability — hardening of auto features

- **AutoAttacher reentrancy guard** (`_ticking` flag). `Timer.periodic` fires regardless of whether the previous tick's Future completed; without the guard, two concurrent ticks could race on `_seenUris` + double-issue `performAttach`. Subsequent ticks are now no-ops while one is in flight.
- **AutoAttacher top-level try/catch.** Any unexpected exception in a tick (e.g. `ConcurrentModificationError` on `_seenUris`, upstream API change) logs to stderr and the watcher keeps polling. Previously a bad tick would silently kill the watcher via the zone's swallowed-exception handler.
- **`_seenUris` cap (1024).** Pathological vmServiceUri churn (hot-restart loop) can't grow memory unbounded. When exceeded, the older half is dropped; safe failure mode because `performAttach`'s per-URI duplicate guard catches re-attach attempts.
- **`CapturesDatabase.open` generic catch** in `main.dart` covers `SqliteException` from schema-migration failures, sqlite3 native errors, and corrupt-DB-on-open scenarios. Previously only `FileSystemException` + `StateError` were handled; other failures crashed with a raw Dart stack. Now exits cleanly with code 70 (`EX_SOFTWARE`) + a recovery hint pointing at `--data-dir <fresh path>`.
- **`LogStreamSubscriber.onError` handlers** on all three VM service stream listeners (`onLoggingEvent`, `onStdoutEvent`, `onStderrEvent`). Synchronous exceptions in listener callbacks and asynchronous stream errors are now routed to stderr; the subscription stays active. Previously a malformed Event or mid-stream disconnect could noisily kill the logging subsystem.

None of this can break the user's Flutter app — the MCP runs in a separate process, communicates with the VM service via read-mostly RPCs, and the only side-effects on the app are profiling toggles (which the VM service is designed for). These hardenings keep US from breaking in the face of weird input; the user's app is unaffected.

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

### Added — auto-attach (`--auto-attach`)

Optional background watcher (off by default) that polls DTD and attaches automatically to apps that appear AFTER the server starts. Naturally builds on multi-attach — apps come and go, the server keeps up without the agent needing to call `network_attach` manually each time.

- New CLI flag `--auto-attach` and env-var fallback `FLUTTER_NETWORK_MCP_AUTO_ATTACH=true|1`.
- Poll interval via `FLUTTER_NETWORK_MCP_AUTO_ATTACH_POLL_MS` (default 5000, clamped 1000–60000).
- **Seed-and-skip on first tick:** apps already running at server startup are NOT auto-attached. The watcher seeds its known set on first poll, then only attaches to URIs that appear in subsequent ticks (a fresh `flutter run` or a hot-restart that spawns a new DDS).
- **Respects manual `network_detach`:** a detached URI stays in the known set, so the next poll tick won't re-attach it. Restart the app or detach + re-attach manually to bring it back.
- **Respects `FLUTTER_NETWORK_MCP_MAX_ATTACH`:** over-cap discoveries log a one-line stderr note and stay in the known set (no retry storm).
- Implementation: `lib/src/auto_attach.dart` (`AutoAttacher` class); wired in `bin/flutter_network_mcp.dart`.

### Added — multi-isolate within one app

A single Flutter app can have multiple isolates (main + worker + spawned compute isolates). Previously the server captured HTTP from **only the first isolate** that exposed `ext.dart.io.getHttpProfile` — worker traffic was silently invisible. 0.6.0 captures from every qualifying isolate and tags each captured row with its source isolate id.

- **Schema v3 → v4** — adds nullable `isolate_id` columns to `http_requests`, `socket_events`, `log_records`, and `http_search_map`. Pre-v4 rows keep `NULL` (treated as "VM-level"; still queryable, never excluded). Covering indexes on `(session_id, isolate_id)` for the per-session-per-isolate query pattern.
- **`VmClient` multi-isolate refactor** — replaced single `_isolateId` with `Map<String, IsolateInfo>`. New `discoverHttpProfilingIsolates()` returns the full list. Per-isolate RPC variants (`getHttpProfileForIsolate`, `enableHttpLoggingForIsolate`, etc.) take an explicit isolate id; the back-compat single-isolate facades stay for the transitional period.
- **Capture writer per-isolate poll** — `_pollHttp` / `_pollSockets` iterate every known isolate each tick with a per-isolate cursor map (so isolates running at different request cadences don't drop each other's data). Periodic 10-tick (~20s) re-scan picks up newly-spawned isolates automatically; new isolates get HTTP/socket profiling enabled before the next poll iterates them. Per-isolate try/catch so one flaky isolate doesn't stop the others.
- **Log stream isolate tagging** — `LogStreamSubscriber._persist` extracts `event.isolate?.id` from VM service events and tags both the in-memory ring buffer and the DB row.
- **`isolateId:` filter on 11 read tools** — `network_list`, `network_get`, `network_body`, `network_clear`, `network_search`, `socket_list`, `socket_get`, `socket_clear`, `logs_tail`. Optional; omit and the tool merges every isolate (single-isolate UX preserved). Per-row responses include `isolateId` when known.
- **Single-id live lookups** (`network_get` / `network_body` / `socket_get`) resolve the right isolate via: explicit `isolateId:` arg → DB-recorded `isolate_id` (writer tags within ~2s) → try each known isolate until one returns the id. Failure reports `triedIsolates: [...]` for disambiguation.
- **`AttachedSession.isolates`** getter delegates to `vm.httpProfilingIsolates` so `network_status.attached[].isolates: [{id, name, number}]` reflects the live set as the writer's re-scan picks up new isolates.
- **`network_attach`** enables HTTP/socket profiling on every discovered isolate (not just the first). Throws when no isolate qualifies (same error message as the old single-isolate path).

### Added — `network_correlate` tool

Typed companion to `network_query` SQL for the **webhook originator + receiver** pattern. When sanga_mobile sends a webhook that sanga_driver receives, `network_correlate sessionIds:[14,15] pattern:"txn-abc-123" timeWindowMs:5000` returns both halves paired by smallest time delta.

- `sessionIds:[int]` is **required** — cross-session aggregation is intentional, so the agent must pick which apps to compare (preventing accidental cross-app data bleed). Hard cap: 8 sessions per call.
- `pattern:string` is **required** — substring searched via FTS5 in URLs and/or bodies. Phrase-quoted automatically so hyphens / colons / special chars work.
- Optional `which: url | request | response | any` (default `any`), `timeWindowMs:int` (only return pairs within this delta — useful for tight request → webhook pairs), `limit:int` (default 20, hard cap 100), `perSessionLimit:int` (default 100, hard cap 500 — bounds raw matches per session BEFORE pairing).
- Pairs are sorted tightest-first (smallest `spanMs`). Output includes `matchesPerSession`, `sessions:[{matches}]`, and `pairs:[{spanMs, requests:[…]}]`. Capability: routes under `search` (reuses FTS5).
- Implementation: new `lib/src/tools/network_correlate.dart` + `CapturesDao.correlateAcrossSessions` (per-session FTS5 query with per-session cap BEFORE union). New `docs/tools/power/network_correlate.md` with DO NOT USE section.

### Added — env vars

- `FLUTTER_NETWORK_MCP_MAX_ATTACH` (default 4, clamped 1–32) — caps concurrent attachments.
- `FLUTTER_NETWORK_MCP_AUTO_ATTACH` (`true`/`1`) — equivalent to `--auto-attach`.
- `FLUTTER_NETWORK_MCP_AUTO_ATTACH_POLL_MS` (default 5000, clamped 1000–60000) — auto-attach poll interval.

### Changed

- **README "32 tools" table** → **33 tools** (`network_correlate` added). New **Scope** column marking which tools accept `sessionId` / `appNameContains` / `isolateId`. New "Multi-attach (0.6.0)", "Multi-isolate within one app", and "Cross-app correlate" sections explain the workflows.
- **`docs/README.md`** gained multi-attach + multi-isolate + correlate callouts at the top; `network_correlate` added to the "Power user / ad-hoc queries" use-case section.
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
