# Agent-UX Audit — flutter_network_mcp

**Date:** 2026-07-02
**Server under test:** Phase 1: 0.8.4 (JIT). Phase 2 (same day, below): 0.9.16 after `flutter_network_mcp update` + MCP reconnect.
**Auditor:** Claude (Fable 5) acting as a fresh agent: MCP schemas + server instructions only, no source code read.
**Method:** Two scenarios. (1) History exploration: "figure out what's in past captures" against the existing 322-session DB. (2) Live debugging: a synthetic Dart testbed app (local HTTP server + client producing 200/201/404/500, a 1.6 s slow call, a connection-refused failure, a 27 KB JSON body, and `developer.log` records at info/warning/severe) attached via `vmServiceUri`, then investigated with the "something's wrong with my app's network" prompt.

---

## Executive summary — why agents "never use it to its full potential"

**Latency is NOT the problem.** Every call returned fast (sub-second, most feeling instant). The problems are trust and routing:

1. **Version drift (most likely the #1 cause).** The MCP server this very session runs is **0.8.4** while the latest release is **0.9.16**. Everything shipped since 0.8.4 — including `capture_allow` (0.9.16), the parameterized ignored-hosts fix (0.9.15), hot-restart reattach polish — is invisible to the agent. If your own daily config launches a stale binary, every iteration you made "for the agents" never reached them. `network_status` even reports `updateAvailable` — but by then the session is already running the old code.
2. **Correctness traps that destroy agent trust.** Agents are Bayesian: one confidently-wrong answer ("no matches", "no requests captured", 0 ms durations) and they downgrade the tool to "unreliable" and quietly fall back to grep/print-debugging. This audit found four such traps (F2, F3, F4, F5 below) — each one produces a *plausible empty/zero answer with misleading guidance* instead of an error.
3. **`nextSteps` is your superpower and your liability.** The consistent `summary`/`scope`/`nextSteps` envelope is the best thing about this tool — it visibly steered my navigation all session. But precisely because agents obey it, the handful of places where `nextSteps` is *wrong* (attach → "call network_list" while a stale history view shadows reads; history cursor → "page beyond the newest"; empty history summarize → "drive the app") actively walk agents into dead ends.
4. **The deep-use documentation is unreachable.** Tool descriptions and error messages repeatedly cite `docs/tools/...` guides, but the server exposes **zero MCP resources** — a fresh agent (who does not have your repo checked out) can never read them. The 38-tool surface is fine *if* the routing docs are in-band; today they aren't.

---

## Findings

Severity: 🔴 launch-blocking · 🟠 high · 🟡 medium · 🟢 polish

### 🔴 F1 — Version drift: sessions run 0.8.4 while 0.9.16 is latest
`network_status` → `{"mcp":{"version":"0.8.4","updateAvailable":{"latest":"0.9.16"}}}`. The agent tool list has no `capture_allow`. **Everything below must be re-verified against 0.9.16 before acting on it** — some findings may already be fixed.
**Recommendation:** for 1.0.0, make staleness loud: a `warnings` entry in *every* `network_status` when `updateAvailable` is set, and consider having the launcher script self-update or at least print the drift at startup. Also verify what your own `.mcp.json` / global config launches.

### 🔴 F2 — Durations are wrong (µs-scale for a 1.6 s request)
The testbed's `/api/slow` endpoint delays 1600 ms before responding. Captured row: `duration_us: 186`, `end_us - start_us: 186` (session 323, vm_id `4051877690651600278`). Every duration in the table is µs-scale; `network_summarize` reported `p50LatencyMs: 0` for it.
**Impact:** all latency features are silently meaningless — `http_slow` alerts can never fire, p50/p95 in summarize is noise, "find the slow endpoint" (a headline use case) is unanswerable.
**Hypothesis:** `endTime` is taken from the request-write-complete lifecycle event rather than response-complete. Check the capture writer's mapping of `HttpProfileRequest` timestamps.

### 🔴 F3 — FTS index race: in-flight requests are never indexed
`network_search query:"slow"` → 0 matches (even `which:"any"`), while `/api/slow` sits in `http_requests` with `bodies_fetched: 1` but has **no `http_search_map` row**. Every request that completed *between* writer ticks got indexed; the one still in-flight at its first tick never did.
Population-level evidence from your own DB: **85,764 `http_requests` vs 73,582 `http_search_map` rows → ~14% of all captures are unsearchable.**
**Impact:** search returns a confident "No matches" plus a misleading warning ("bodies may not be indexed yet… or the query is too specific") for data that exists. This is the classic trust-killer.
**Recommendation:** index on completion (or re-visit pending rows on subsequent ticks); add a repair pass at attach/startup that indexes any row missing from the map.

### 🔴 F4 — Stale history view silently shadows live reads after attach
Repro: `session_open id:322` → later `network_attach` (new live session 323) → bare `network_list` returns **session 322 history**, because the explicit view outranks the live session in scope resolution. Worse, the attach response's own `nextSteps` says "Then call network_list / logs_tail / alerts_drain" — walking the agent straight into stale data. The view is server-process state, so it even leaks across *conversations*.
**Recommendation:** `network_attach` should either auto-close the history view or return a loud warning ("a history view of session 322 is open; reads will NOT hit this live session until session_close"). Same warning belongs on every read response whose `scope` came from a view while a live session exists (a one-line `warnings` entry is enough).

### 🟠 F5 — `network_summarize` default window is a trap in history mode
Viewing 3-day-old session 322 (207 requests), a bare `network_summarize` → *"No HTTP requests captured over 1h"* with nextSteps *"Drive the app to generate traffic, then re-run"* — wrong on both counts. `sinceMs:0` then produced a perfect digest.
**Recommendation:** when the scoped session is a history view (or is ended), default `sinceMs` to 0 / the session's own time range. Never emit "drive the app" advice for an ended session (same bug in `logs_tail` history mode and F8).

### 🟠 F6 — `network_list` cannot page backwards; cursor advice dead-ends in history
`since` is a *floor* and results are newest-first with a 200-row hard cap, so in a >200-request session the oldest rows are unreachable via the typed tool (SQL becomes mandatory). In history mode the suggested `network_list since:<nextCursor>` ("page beyond the newest in this batch") by definition returns 0 rows — and that empty response then suggests "Widen filters", misdiagnosing the situation.
**Recommendation:** add a `before`/descending cursor (or make `nextCursor` point *older* in history mode), and make the empty-result hint cursor-aware.

### 🟠 F7 — `network_get` returns credentials unredacted
Response included raw `authorization: Bearer SECRET123XYZ` and `x-api-key: APIKEY987`. Only `network_replay` redacts (it did, correctly, including the custom-list machinery). Real bearer tokens will land in agent transcripts, logs, and any telemetry that captures tool results.
**Recommendation:** redact by default in `network_get` using the same built-in + `redacted_headers` set, with `redact:false` opt-out, mirroring replay's flag. (Debugging auth flows still works — the agent opts out deliberately, which is also an auditable signal.)

### 🟠 F8 — Referenced docs are unreachable; zero MCP resources
- `network_query` description: "Schema lives in docs/tools/power/network_query.md"
- `network_query` error nextSteps: "see network_query tool description" (circular)
- Server instructions: "See docs/tools for per-tool guides"
- `ListMcpResources` → **none**.
A fresh agent without the repo cannot read any of these. I had to *guess* the SQL schema (naming is good — `http_requests` worked first try — but the FTS/table topology, `vm_id` vs `id`, `duration_us` units etc. all required trial and error; my first two queries failed on column names).
**Recommendation:** expose `docs/tools/**` as MCP resources AND embed the compact table schema directly in the `network_query` description. For 1.0.0 this is cheap and high-leverage.

### 🟡 F9 — Alert scope whiplash + unbounded accumulation
Before attach, every response carries global `pendingAlerts: {count: 13780, critical: 2}` (322 sessions of accumulated noise — mostly your own test runs). After attach the same field silently switches to live-session scope (`count: 5`). A session-scoped `alerts_peek` shows 0 while the banner says 13,780. Alerts never age out.
**Recommendation:** label the scope in the payload (`pendingAlerts: {scope: "live" | "global", ...}`), stop injecting the global figure once a session is scoped, and add retention (auto-drain/expire alerts from ended sessions after N days, or exclude ended sessions from the banner count).

### 🟡 F10 — DTD failure output is confusing and doesn't route to the fix
`network_status` showed `defaultUri` on port **50027** while `connectError` mentions port **51899** — two ports, no explanation. `nextSteps` said "check the URI is still valid" but did not mention `network_discover_dtd`, the tool that exists exactly for this. (Discover itself behaved well: dead-pid warning + `includeStale` hint.)
**Recommendation:** make the failed-DTD `nextSteps` point at `network_discover_dtd`, and don't show a connect error for a different endpoint than `defaultUri` without labeling which is which.

### 🟡 F11 — Session liveness tri-state reads incoherently
`session_open id:322` → summary *"Viewing session 322 (unnamed, **still live**)"* alongside `isLive: false, isEnded: false`, while `session_list` says "live: none". These are crashed/never-detached sessions.
**Recommendation:** introduce an explicit `orphaned`/`interrupted` state for sessions with no end marker and no live attach; never print "still live" unless it is the attached session.

### 🟡 F12 — "Writer may still be backfilling" on 3-day-old dead sessions
`network_get` in history mode warned *"Request body not persisted yet (writer may still be backfilling)"* for a session whose process is long gone. It will never backfill.
**Recommendation:** in history mode say "body was never captured before the session ended".

### 🟡 F13 — `alerts_config` self-contradiction + schema drift
Summary says "6/6 rule(s) enabled" while the config lists **7** rules; `http_anomaly` exists server-side but is absent from the tool's input schema (can't be toggled). Likely 0.8.4-era drift, but it's the kind of mismatch that makes agents second-guess the contract.

### 🟡 F14 — `network_query` silently ignores the session view
While "viewing" session 322 I ran an aggregate and got all-sessions results (85k rows) with no scope indication. Cross-session is the documented intent, but the response should say so (`"scope": "all-sessions"`), because every sibling read tool honors the view.

### 🟡 F15 — Semantic truncation and byte paging don't compose
`network_get` semantic mode is excellent (pretty-printed JSON, "5 of 400 shown, 395 more") but returned 594 transformed bytes while `nextSteps` suggested `network_body offset:4096` — an offset into the *raw* 27,207-byte body that corresponds to nothing the agent has seen. Byte paging itself works fine (`nextOffset` chaining verified).
**Recommendation:** when semantic truncation was used, phrase the follow-up as `offset:0` (fresh raw read) or add semantic paging (`itemsOffset`).

### 🟢 F16 — Misc polish
- `network_status.nextSteps` on DTD failure could also mention `attachIfOne` for the happy path.
- `session_list` shows temp-dir test sessions (`/private/tmp/fnmcp-master-*`) indistinguishably from real ones — a `kind` or note would help filtering.
- Export warns "session is still live" — good; consider including the HAR spec version in the payload.

---

## What already works well (keep and advertise these)

| Feature | Evidence |
|---|---|
| `alerts_drain` triage | Deduped 5× identical 500s into one alert with `occurrenceCount:5`; caught stderr SocketException, SEVERE log, "timeout" keyword; source ids link alert→request/log; severity breakdown up front |
| `network_summarize` | Path templating collapsed `/api/profile/42`+`/91` → `/api/profile/N`; nextSteps *noticed the non-zero error rate* and routed to alerts_drain |
| Semantic JSON truncation | 27 KB body → 594-byte faithful preview with explicit "395 more, 5 of 400 shown" |
| Body FTS search | Phrase "pool exhausted" → matched 500 bodies with «highlighted» snippets, BM25-ranked |
| `network_body` paging | Correct `nextOffset` chaining, utf8/base64 auto-decode |
| `correlate_at` | Signed `deltaMs`, nearest-first — exactly the "which request fired near this log?" answer |
| `logs_tail` | stdout/stderr/logging unified, levels + logger names + error fields, `severeCount` surfaced |
| `network_replay` | Redaction on by default, correct curl |
| `network_diff` | Honest "identical" verdict; honest about missing bodies |
| `network_query` | Guessable schema names, real SQLite errors + recovery hint, auto row cap |
| `db_stats` / maintenance | Honest size warnings, actionable purge/vacuum routing |
| Envelope consistency | `summary`/`scope`/`nextSteps` on every response — the tool teaches its own usage |
| Latency | Uniformly fast; the "latency problem" theory is **not supported** |

---

## Not yet tested (phase 2, with a real app)

- DTD discovery → `network_attach appNameContains` happy path (the most common real-world entry)
- Auto-attach (`attachIfOne`, `auto_attach_config`)
- Multi-attach + `network_correlate` (needs 2 apps)
- Hot-restart `reattach:true` continuity
- `ignored_hosts` / capture allowlist against real analytics noise
- `alert_patterns` add/remove lifecycle
- Destructive paths: `bodies_purge`, `session_delete`, `db_vacuum` (dry-run contracts)
- Real Flutter app with multiple isolates, websockets, gzip, redirects, multipart

---

# Phase 2 — re-verification on 0.9.16 + new-tool review

Server updated (`0.8.4 → 0.9.16`, git `1e6d29 → 089e9f`) and reconnected. Root cause of F1 confirmed: the binary was a **git-pinned `pub global activate` snapshot** — every push since activation never reached the running server. Consider making `flutter_network_mcp update` part of the release story (or an AOT binary with a self-update check that refuses to silently run months stale).

## Finding status after re-test

| # | Finding | 0.9.16 status |
|---|---|---|
| F1 | Version drift | Root-caused (git-pinned activation). New nit: `updateAvailable` still shows `latest: 0.9.16` *while running 0.9.16* — no comparison against the current version. |
| F2 | Durations wrong | **UNFIXED — re-proved live.** `/api/slow` captured with `durationMs: 0–1` while the request timeline shows the next call firing 1,608 ms after its start. `endTime` is stamped at request-send-complete, not response-complete. |
| F3 | FTS misses in-flight requests | **UNFIXED + messaging regression.** The no-match warning now asserts *"The capture is indexed, so the term is too specific or absent"* — a confident falsehood when the row was skipped. (The new `availableHosts` hint is genuinely nice.) |
| F4 | History view shadows live reads | **UNFIXED** — re-reproduced verbatim on 0.9.16. |
| F5 | Summarize 1 h window trap in history | UNFIXED. |
| F6 | Cursor can't page older / dead-end advice | UNFIXED, and it has a new sibling: the `maxResponseTokens` trim warning also says "page with `since:<nextCursor>`" although the dropped rows are *older* than the cursor. Related: with no filters passed, the response warns "Filters dropped 48 of 51 … consider widening" — it conflates `limit` + token-budget trimming with filtering. |
| F7 | `network_get` leaks auth headers | UNFIXED (`authorization: Bearer …` returned raw again). |
| F8 | Docs unreachable, zero MCP resources | UNFIXED. |
| F10 | DTD error port mismatch, no discover routing | UNFIXED. |
| F11 | "still live" on dead sessions | UNFIXED. |
| F12 | "writer may still be backfilling" | Partially improved: new `bodyStatus` fields (`empty`/`stored`) are great — but the stale warning still fires *alongside* `bodyStatus:"empty"`, contradicting it in one payload. |
| F13 | alerts_config "6/6" vs 7 rules; `http_anomaly` missing from input schema | UNFIXED. |

## New findings on 0.9.16

### 🔴 F17 — Pre-attach traffic is silently lost
Attaching ~60 s after app start: session 324 contained only post-attach heartbeats — the entire checkout burst (POST /orders, /big, /slow, two 404s) was missing, with no indication anything was skipped. The VM's HTTP profile *retains* that backlog (DevTools shows it); the writer just starts its cursor at "now".
**Recommendation:** ingest the existing profile backlog on attach (flagged `preAttach: true`), or at minimum return `"N earlier requests existed in the VM profile and were not captured"` in the attach response.

### 🔴 F18 — App death is never detected; the server reports a healthy attach forever
Killed the app while attached. 5+ seconds later: `network_status` → `attachedCount: 1`, `capabilities: {http: ok, socket: ok, logs: ok}`; `network_list` → "Drive the app to generate traffic". An agent will keep polling a corpse — and your own `usage_stats` shows past agents did exactly that (`unresponsive_vm` ×4).
The per-call story is actually good: `socket_list` hit the dead VM and degraded honestly (`degraded: true`, "Service connection disposed → returned the persisted DB snapshot"). But that signal never updates session state.
**Recommendation:** listen for the VM WebSocket close (or treat the first `connection disposed` as terminal): end the session, and have status/reads say "app exited at <ts>; session 325 is now history".

### F19 — `usage_stats` empirically corroborates the audit
From real prior usage: `network_search` **54% empty-rate** with `empty → search again` as its top transition (F3's fingerprint); `network_query` **53% error-rate**, all `bad_query` (F8's fingerprint — no reachable schema); every tool p50 ≤ 155 ms (latency hypothesis dead). Its own nextSteps flags the query error rate. This tool is a launch differentiator — put it in the README.

## New tools (0.9.16) — assessment

| Tool | Verdict |
|---|---|
| `network_body_outline` | **A+. The context-efficiency flagship.** 27 KB body → typed skeleton with per-branch byte counts and array element shape, ~40 lines. |
| `network_body_query` | A. `jsonPath` extraction returned exactly one value from a 27 KB body; pairs perfectly with outline. |
| `network_replay_as_test` | A. Valid Dart test, auth redacted as commented-out placeholders, status + body assertions. |
| `alerts_drain` `priorOccurrences` | A. Cross-session recurrence per alert signature — instant "this also happened in session 323/324" regression context. |
| `usage_stats` | A. See F19. |
| `session_configure` | B+. Sticky filters + `maxResponseTokens` budget work (`budget.dropped` reported); trim-hint direction bug noted in F6. |
| `network_report` | B+. Great triage headline ("Top problem: GET /api/flaky failing 100%") but weak routing: suggests `network_search query:"127.0.0.1"`, which matches every request in the session — it already knows the failing path, so suggest `statusMin:500` or the path itself. |
| `network_diff_session` | B+. Correct endpoint-level new/gone/changed with count context. |
| `network_drift` | B. Clean no-drift verdict; positive-drift path untested. |
| `capture_allow` | A−. Clear semantics, env-union documented in output. |

---

# Phase 3 — extended surface coverage (0.9.16)

Setup: two testbed instances attached simultaneously (multi-attach), producing gzip responses, a 302 redirect, a WebSocket echo session, a unicode query param, a 600-line log burst, and shared `traceId` values across both apps. Then filter tools, adversarial inputs, lifecycle edges, and the maintenance/destructive contracts.

## New findings

### 🔴 F20 — `ignored_hosts` mid-session changes have NO effect (config snapshot at attach)
Added `127.0.0.1/api/ok`, then plain `127.0.0.1` — both responded "Capture writer refreshed", yet already-attached sessions kept capturing everything for minutes. Controlled experiment: a session **freshly attached while the ignore was active captured 0 rows**; the pre-existing session kept capturing at full rate the whole time.
**Root cause (verified):** per-session writers snapshot the skiplist at attach; the "refresh" never reaches running writers. `capture_allow` shares this machinery and is almost certainly equally inert mid-session.
**Impact:** the headline "silence the noise mid-session" workflow (and the 0.9.16 `capture_allow` feature) silently does nothing in the most common case, while claiming success.

### 🟠 F21 — WebSocket upgrades raise a false `http_error` alert
A perfectly successful WS handshake (`101`, echo verified) produced severity-error alert *"GET /ws — request failed · Socket has been detached"*. Every WS connect in a real app would pollute `alerts_drain` with a phantom error.

### 🟠 F22 — Redirects: chain invisible, final body lost
`/api/redirect` (302 → `/api/ok`) is recorded as a single 200 with no redirect hop anywhere (not even in `events`), and its final response `bodyStatus` is `empty`. Debugging redirect loops / wrong-Location bugs is impossible; the 302 also never got FTS-indexed (see RC2).

### 🟡 F23 — URLs are FTS-indexed percent-encoded
`?coupon=%C3%9CMLAUT` is only findable as `9CMLAUT`; searching `ÜMLAUT` misses. Index the decoded form (too) for i18n apps.

### 🟡 F24 — `network_correlate` returns every request twice
Full request objects (with identical snippets) appear in both `sessions[]` and `pairs[]` — the response was ~2× the tokens it needs. Reference pair members by id.

### 🟡 F25 — `reattach:true` silently degrades to a fresh session
With no matchable identity (appName null on raw-VM attach), reattach quietly created session 328 with zero acknowledgment that reattach was requested or why it failed to match.

### 🟡 F26 — Bad request-id errors are misclassified as `unresponsive_vm`
`network_get id:"no-such-id"` errors with `errorKind: "unresponsive_vm"` although the VM answered fine. This muddies `usage_stats` telemetry (the historical `unresponsive_vm ×4` conflates dead apps with typo'd ids). Related design gap: `network_get` requires the live VM even when the row is fully persisted — `socket_list` has a graceful `live-db-fallback`, `network_get` has none.

## What phase 3 verified as working well

- **Scope-ambiguity guard**: with 2+ sessions attached, bare reads fail with a precise error listing each session and copy-pasteable `sessionId` nextSteps. Attach #2's response pre-warns about it. Model behavior.
- **Log-ring overflow**: 600-line burst → `500/500` with a warning that correctly routes to history mode (the DB kept everything) or a bigger buffer. Exactly right.
- **Custom alert patterns**: add → fires on matching logs (deduped, `occurrenceCount`, `priorOccurrences` across sessions) → remove. Clean lifecycle; the removal hint even suggests clearing already-fired alerts.
- **`network_correlate` correctness**: found all cross-session pairs by shared `traceId` with tight `spanMs` and originator/receiver framing.
- **SQL guardrails**: multi-statement, UPDATE, and injection attempts all rejected with `bad_query` + actionable hints.
- **gzip**: transparently decompressed (`compressionState: decompressed`), bodies searchable.
- **Destructive contracts**: `session_delete` and `bodies_purge` default to informative dry-runs ("would delete X… Cannot be undone", backup suggestion); `alerts_clear` honors drained-only; `db_vacuum` reports honest before/after.
- **Custom redaction registry** works when `redact:true` (masked `authorization` + the custom header).
- **`network_status` multi-attach view**: `perAttached` alert counts, per-session isolates, buffer usage — rich and readable.
- ⚠️ One regression: `network_replay` now defaults `redact:false` (0.8.4 defaulted true) — raw bearer token in the curl. Deliberate per the docs, but it makes the `redacted_headers` registry inert by default and compounds F7.

## Still untested (needs the real app / DTD)

DTD-name discovery + `attachIfOne` + `auto_attach_config`; hot-restart reattach with a real DTD identity; multi-isolate capture (my Dart testbed couldn't spawn one cleanly); `flutter_error` alert rule; positive-drift path of `network_drift`; `capture_allow` live filtering (blocked by F20 anyway); AOT-mode server.

---

# Root-cause map — the fixing sprint should work THIS list, not the symptoms

| RC | Root cause | Findings it explains | The one fix |
|---|---|---|---|
| **RC1** | Capture writer stamps `endTime` from the request-send lifecycle event, not response-complete. Proof: `network_get events` shows "Content Download" at +6 ms while `endTimeMs` == the "Request sent" timestamp; a 1.6 s response recorded as 186 µs. | F2 (all durations ~0), dead `http_slow` rule, meaningless p50/p95 in summarize/report/diff_session | Use the response-complete event (fall back to last event) for `end_us`/`duration_us`. |
| **RC2** | FTS insertion happens exactly once per request, at first sight, and only if the response is already complete; incomplete rows are never revisited (bodies are, the index isn't). Proof: in one session the ONLY unindexed rows are the delayed (`/api/slow`), multi-hop (`/api/redirect`), and held-open (`/ws`) requests; ~14% of all historical rows lack index entries. | F3 (unsearchable requests), the false "capture is indexed" warning, part of F22 | Enqueue FTS insert on completion; add a startup/attach repair pass for rows missing from `http_search_map`; make the no-match warning check coverage before claiming "indexed". |
| **RC3** | **(mechanism corrected in phase 5, fixed in 0.9.18)** The filter-mutation tools refreshed `Session.instance.captureWriter`, which resolves to `soleAttached ?? stub` — with 2+ sessions attached the refresh hit a stub writer: a silent total no-op. Single-attach worked, which is why it survived manual testing. (The phase-3 "config snapshot at attach" hypothesis was the observable of this, not the cause.) | F20 (`ignored_hosts`/`capture_allow` no-op mid-session under multi-attach), the false "Capture writer refreshed" summary | `SessionRegistry.refreshCaptureFilters()` pushes to every attached writer; all four call sites migrated; `activeCaptureFilter` exposed for tests. |
| **RC4** | No VM-lifecycle subscription: sessions end only on explicit detach. | F18 (healthy-looking zombie attaches, "drive the app" advice for dead apps), F11 ("still live" orphan sessions), F17-adjacent confusion, stale `attachedCount` | Listen for VM WebSocket close / isolate exit → end session, record `endedReason: "app exited"`, surface it in status + reads. Mark legacy orphans. |
| **RC5** | Live reads are VM-first with inconsistent DB fallback, and error taxonomy conflates causes. | F26 (bad id → `unresponsive_vm`), `network_get` failing on dead VMs while `socket_list` degrades gracefully, polluted usage_stats errorKinds | One uniform read path: DB when persisted, VM only for the not-yet-persisted tail; distinct `not_found` vs `unresponsive_vm` kinds. |
| **RC6** | Scope resolution has invisible process-global state (`session_open` view) that outranks the live session, and ambient scope labels are inconsistent. | F4 (view shadows live after attach, leaks across conversations), F9 (pendingAlerts banner flip-flops global/session), F14 (`network_query` silently global) | Make attach auto-close (or loudly flag) an open view; add `scope` labels to every ambient counter; echo effective scope in `network_query`. |
| **RC7** | Cursor + window semantics were designed for live-incremental reads and reused unchanged for history/pagination. | F5 (1 h summarize window on a 3-day-old session + "drive the app"), F6 (no older-than paging, "page beyond the newest" dead-end, "widen filters" misdiagnosis, budget-trim hint pointing the wrong way) | History-aware defaults (`sinceMs:0` when viewing ended sessions); a `before` cursor; hints derived from cursor direction + actual filter state. |
| **RC8** | `nextSteps`/warnings are static templates not validated against the state they're emitted in — and agents *obey* them. | Attach advice that walks into the F4 trap, "drive the app" on ended sessions (F5/F12/logs_tail), status advertising a drain call that then errors pre-attach, `network_report`'s useless `query:"127.0.0.1"` suggestion, `updateAvailable` shown when current (F1-nit), "6/6 rules" vs 7 (F13) | Route all guidance through one builder that receives (liveness, mode, scope, filters); add a test that executes every emitted nextStep in the emitting state. Highest leverage-per-effort fix in the list. |
| **RC9** | Redaction is opt-in and only wired into replay (default now off). | F7 (`network_get` raw tokens), 0.9.16 replay regression, inert `redacted_headers` registry | Redact-by-default across get/replay/export/tests with a single explicit `redact:false` opt-out. |
| **RC10** | Deep docs live in the repo, not in the protocol. | F8 (unreachable schema/guides), 53% `network_query` error rate, agents guessing | Expose `docs/tools/**` as MCP resources; embed the table schema in the `network_query` description. |

Standalone smaller fixes outside the map: F10 (DTD error ports + route to `network_discover_dtd`), F15 (semantic truncation vs byte-offset advice), F21 (suppress `http_error` for 101 upgrades), F22 (record redirect chain + final body), F23 (index decoded URLs), F24 (dedupe correlate payload), F25 (acknowledge failed reattach), F17 (ingest or announce pre-attach backlog), name raw-VM sessions by host:port so multi-attach labels aren't "(no name)".

---

# Phase 4 — live 4-app test (real apps, DTD path, 0.9.16 installed server)

Setup: sanga_driver (iPhone Air), starlog (iPhone 17e), sanga_mobile (iPhone 17 Pro), aetrust (iPhone 17), all `flutter run` debug. Server launched with `--auto-attach=sanga_mobile,sanga_driver`.

## Tool findings (new or upgraded)

- **F18 confirmed in the wild**: a sanga_driver session whose app had died ~10 min earlier still reported `isLive`, `streamActive: true`, and "Drive the app to generate traffic". RC4 fix (this branch) addresses exactly this.
- **F27 (new, 🟠): auto-attach missed a matching app.** `sanga_mobile` was on the allowlist and visible in knownApps but never auto-attached (the two sanga_driver instances did). Likely tied to the stale default-DTD connect error (`dtd.connected: false` against a dead port while per-app dtdUris were live). Needs a look at AutoAttacher's DTD source.
- **F28 (new, 🟠): degraded attach never self-heals.** Session 332 attached with `http/socket: unavailable` (attach raced app startup), app lived ≥3 more minutes, capabilities never recovered and nothing suggested re-attaching.
- **F24 upgraded**: `network_correlate` with `limit:3` still dumped all 40 per-session matches (~8k tokens) for a zero-pair answer. Cap `matches` too, or add a compact mode.
- **F29 (new, 🟡): DTD app names are unwieldy**: `"Kind: Flutter - Device: iPhone Air - Package: sanga_driver"` — verbose for appNameContains, collides across devices for the same package. Parse into `{package, device}` fields and key display on package.
- **F30 (new, 🟢): wss URLs render with `:0` port** in alert titles (`https://nexus.sangaeats.com:0/socket.io/...`).
- **F21 confirmed live**: every socket.io WebSocket upgrade raises a phantom `http_error` ("Socket has been detached") — one per app per connect, polluting alerts on real apps constantly.
- **F26 confirmed live**; max-attach cap of 4 surfaced with a clean, well-routed error (good), though the cap consumed a slot on a dead session until manually detached (RC4 fixes).
- **Auto-attach suggestion block is excellent** (explicit agentAction + shell line + "don't edit rc without confirmation") — keep.

## Real app bugs found during the blind test (for the user)

1. **sanga_mobile: expired-refresh-token retry loop.** `POST /auth/refresh` → 401 "Invalid or expired refresh token"; the JWT's `exp` (1782847758) passed ~39 h before the test, and priorOccurrences shows the same 401 across sessions since June 24. The app keeps retrying the dead token instead of clearing it and routing to re-login.
2. **aetrust: plain-HTTP raw-IP backend.** All traffic goes to `http://31.220.81.46:8086` with a full `Bearer` token — unencrypted; token issuer `http://aetrustintegmicro:3000`. Responses also never complete in the profiler (chunked/streamed consumption), so no status codes are captured.
3. **sanga_driver: 15–30 s polling loop** on `/driver/deliveries/me?page=1&limit=20` plus long-poll socket.io — by design perhaps, but it's the app's dominant traffic.

---

# Phase 5 — cross-tool scenario (glint drives, fnmcp observes) + RC3 correction

- **Combined workflow verified**: glint attached to starlog/"Summit" (after building its iOS bridge — glint note: the "bridge not found" warning prints a relative path and attach caches the resolution; pass `iosBridgePath` or restart), tapped through nav tabs; fnmcp's `logs_tail` on the same app showed the GoRouter pushes, a socket.io WebSocket lifecycle (`disconnected: transport close` → reconnect → "Joined team room"), and the socket.io upgrade request. An app that looked network-silent was revealed as WebSocket-driven via logs — exactly the layered observability story.
- **`network_body_outline` on a real 26 KB delivery-list response**: full typed schema (31-key nested objects, arrays with element shapes, per-branch byte counts) in one compact call. Flagship behavior confirmed on real data.
- **`network_drift`** across 44 real samples: clean stable-contract verdict.
- **RC3 mechanism corrected** (see updated root-cause map): the live test initially looked like the mid-session ignore worked — but the polling had stopped 13 minutes earlier (a confound). Code reading found the true cause: the refresh goes through `Session.instance.captureWriter` = `soleAttached ?? stub`, so under multi-attach it refreshes a stub. Fixed in 0.9.18 with `SessionRegistry.refreshCaptureFilters()` + a regression test. Audit lesson recorded: a "worked once" live probe is not verification when the mechanism is scope-dependent.

---

# Phase 6 — live verification of the fixes on 0.9.18 (post-reconnect)

All four fixed root causes verified against the running server + real/testbed apps:

| Fix | Live evidence |
|---|---|
| **RC1 durations** | `/api/slow` captured with `duration_us: 1,604,086` (1604 ms for a 1.6 s response) via the repro harness (`tool/rc_repro.dart`) on identical code — previously 186 µs. |
| **RC2 search** | The phase-2 failing query (`network_search sessionId:323 query:"slow"`) now returns the hit — the startup repair pass indexed the historical gap. DB coverage went from ~86% to **99.98%** (86,987 / 87,001; remainder = live in-flight rows). Coverage-aware no-match messaging confirmed. |
| **RC3 filters** | With **3 sessions attached** (the stub-refresh trap), `ignored_hosts add 127.0.0.1/api/ok` stopped `/api/ok` capture within one tick (0 new rows over 4 heartbeat cycles) while `/api/flaky` kept flowing and other sessions were untouched. |
| **RC4 app death** | Killed the attached testbed twice: within ~4 s `network_status` dropped the session and reported `recentlyEnded: [{sessionId, endedReason: "app exited", diedAtMs}]`. No more zombie attaches. |
| **Lifecycle guard** | The pre-fix 0.9.16 server orphaned by this `/mcp` reconnect was the LAST of its kind (killed manually); 0.9.18 exits on stdin EOF. |
| **F27 (auto-attach miss)** | Resolved on restart: the fresh server auto-attached BOTH allowlisted apps in seconds. Root was the long-lived server's stale DTD state — fold "re-discover DTD when the default URI dies" into the backlog. |

## F17 mechanism corrected

Phase 2 assumed the VM profile retains pre-attach traffic ("ingest the backlog"). Live `since:0` reads prove otherwise: **dart:io HTTP profiling records nothing until `httpEnableTimelineLogging(true)`, which attach performs** — the pre-attach requests were never recorded at all (two clean demonstrations: a session that attached mid-flow captured everything after the attach instant and nothing before). So the backlog is unrecoverable by design; the correct fix is honesty + earliness: (1) the attach response should state "HTTP profiling enabled now — traffic before this instant was not recorded"; (2) auto-attach from launch (the allowlist flow) is the real mitigation and it works.

## New (0.9.18) observations

- `updateAvailable: {latest: "0.9.16"}` shown while running 0.9.18 — the daily-cached "latest" is stale and the comparison doesn't suppress when current ≥ latest. Cosmetic but silly; suppress when not actually newer.
- The writer advances its per-isolate cursor BEFORE processing the batch (capture_writer `_pollHttp`); any mid-batch exception permanently drops the remainder. No live occurrence observed, but it's a latent data-loss edge — advance the cursor after the loop (or per-request try/catch).

## Scenario coverage matrix (what "real-life tested" now means)

Verified live: DTD discovery + named attach + auto-attach allowlist; 4-way multi-attach + scope disambiguation + max-attach cap; app-death lifecycle; history mode + repair; alerts (4xx/5xx/error/log/custom patterns/slow-threshold config, cross-session priorOccurrences); search (URL + body + coverage); summarize/report/drift/diff/correlate on real traffic; body outline/query/paging on a real 26 KB payload; replay + replay-as-test; ignored_hosts/capture_allow mid-session; session lifecycle (open/close/note/export/delete dry-runs); db stats/vacuum/purge dry-runs; SQL guardrails; glint-drives-fnmcp-observes cross-tool flow.
Deliberately NOT covered (needs environments this machine/session lacks): Android emulator + physical devices; hot-restart `reattach`/auto-migration under a real IDE restart; AOT-compiled server (`flutter_network_mcp install`); `--no-persist` mode; DB rolling-cap eviction under pressure; `network_drift` positive case (needs a backend contract change mid-session).

## 1.0.0 gate, final (root-cause order)

1. **RC1** (durations) · 2. **RC4** (app-death lifecycle) · 3. **RC2** (search completeness + honest messaging) · 4. **RC3** (config propagation — or ship `capture_allow`/mid-session `ignored_hosts` as attach-time-only and say so) · 5. **RC6** (scope shadowing) · 6. **RC9** (redaction posture) · 7. **RC7 + RC8** (history ergonomics + validated guidance) · 8. **RC10** (in-band docs).
Then re-run this audit protocol and watch `usage_stats`: search empty-rate (54%) and query error-rate (53%) are the regression metrics for the sprint.
