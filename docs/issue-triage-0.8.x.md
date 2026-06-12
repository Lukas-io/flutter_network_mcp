# Issue triage & fix plan — #13–#21

> Real dogfooding feedback from one ~2-hour debugging session against
> the Roqqu app (`roqquapp`), filed all at once on 2026-06-09.
>
> **Verification basis.** The reporter was on **0.6.2** (per the
> `network_status` blocks in #13/#14; the UX issues #15–#21 didn't
> state a version). Every item below was re-checked against the
> **unmerged 0.7.x/0.8.0 stack tip** (branch
> `feat/0.8.0-realtime-investigation`, = PRs #8–#12), so "already
> fixed in the stack" reflects code the reporter never ran. Where the
> stack already closes part of an issue, it's marked `[x]`.

## Status legend

- `[x]` already implemented in the unmerged stack — verify, then close the issue
- `[ ]` to build
- ~~strikethrough~~ — won't do; reason inline (non-goal)

## Severity & proposed sequencing

Per the established one-PR-per-release workflow. New work branches off
`master` **after** the 0.7.x stack (#8–#12) merges, or stacks on its tip.

> Version note: the "0.8.0" investigation PR (#12) shipped docs only and
> did **not** bump `pubspec.yaml`/`version.dart` — last real bump was
> 0.7.4 (#11). So the first release below can legitimately be **0.8.0
> proper**. Numbers are a proposal; reorder freely.

| Release | Issues | Theme | Why grouped |
|---|---|---|---|
| **0.8.0** | #13, #14, #17 | Trust-breaking bugs | These make the tool give wrong/empty answers silently |
| **0.8.1** | #15, #21, #20 | Quick wins | Small, high-value, no API breakage |
| **0.8.2** | #16 | Hot-restart identity | Biggest single ergonomics win; its own release |
| **0.8.3 / backlog** | #18 (correlation + sticky) | Interactive debugging | Larger surface; live-tail stays parked |
| n/a | #19 | Positive feedback | Convert to do-not-regress guards |

---

## #13 — `network_get` returns `null` response body forever  ·  BUG · P0

**Status: SHIPPED in 0.8.0** (gate relaxation + attempt cap + accurate
diagnostics). See the 0.8.0 CHANGELOG; unticked boxes below (e.g. `partial:true`
flag, live DB fallback) are deferred follow-ups.

`captures_db.dart:192` `pendingBodyFetches` selects rows
`WHERE bodies_fetched=0 AND end_us IS NOT NULL`. `end_us` comes from
`HttpProfileRequest.endTime` (`upsertHttpRequest`, captures_db.dart:109).
For chunked gzip responses dart:io never flips `endTime`, so `end_us`
stays NULL → the row **never enters the backfill queue** → the body is
never fetched → `network_get` returns `response: null` indefinitely.
The bytes exist in the profiler (the app rendered them); we simply
refuse to fetch them.

- [ ] Relax the backfill gate: also fetch rows with `end_us IS NULL`
      once `start_us` is older than a short grace window (~3s), so
      streamed/chunked responses get a body-fetch attempt
- [ ] On-demand live re-fetch in `network_get`: for a LIVE session whose
      stored row has no body, call `getHttpProfileRequest` synchronously
      before returning `null` (instead of the stale "not yet complete"
      warning that never resolves)
- [ ] Cap re-fetch attempts per request (back off) so genuinely-streaming
      SSE / long-poll requests don't get hammered every tick
- [ ] Return available-but-partial bodies with a `partial:true` flag
      rather than `null`
- [ ] Confirm `status_code` populates — #13 also noted the 200 was
      missing from `network_list` (same cause: `response` was null)
- [ ] Repro fixture: a chunked gzip POST; regression test on the gate
- [ ] Verify `network_search query:"charge_frequency"` works afterward
      (the exact capability the reporter lost)

---

## #14 — `network_attach appNameContains` fails while app is in `knownApps`  ·  BUG · P1

**Status: SHIPPED in 0.8.0** (cross-DTD `appNameContains` resolution + accurate
per-case errors).

`network_attach` connects to a **single** DTD (`dtdUri ?? defaultDtdUri`)
and calls `getConnectedApps()` on just that one (network_attach.dart:142-152).
But `network_status.knownApps` aggregates across **all** discovered DTDs
(multi-DTD probe, 0.6.2). In #14 the two iPhone sims were on different
DTDs (`:55580` vs `:59639`), so the matcher never saw the target and hit
the early "no connected apps yet" return.

- [ ] Resolve `appNameContains` across **all** discovered DTDs (reuse the
      probe that powers `knownApps`), not only the default DTD
- [ ] Fix the misleading error: when an `appNameContains` was supplied,
      never say "DTD reports no connected apps yet" — say "no app matched
      '<filter>'; visible apps: [...]" with the candidate list
- [x] Distinct ambiguous-match error already exists for the single-DTD
      case (network_attach.dart:177) — extend it to the multi-DTD path
- [x] "No name contains" error with candidate list already exists
      (network_attach.dart:161) — extend to multi-DTD
- [ ] Test: two apps on two DTDs; `appNameContains` resolves the correct
      one without an explicit `vmServiceUri`

---

## #15 — `logs_tail` needs `messageContains`  ·  UX · small

**Status: OPEN.** `logs_tail` filters only by `levelMin` + `loggerContains`
+ source (logs_tail.dart:77-78). Roqqu's `rqLog` calls have empty
`loggerName`, so the only useful filter doesn't apply → repeated
`limit:500` pulls that busted Claude's 25k output cap.

- [ ] Add `messageContains: string` — case-insensitive substring match on
      the message body, applied at the DB/API layer before returning
- [ ] Accept a list form `messageContains: ["EventTracker","KycTier"]`
      (OR-match) so multiple tags come back in one call
- [ ] Update `_filterDesc` (logs_tail.dart:264), tool description, and the
      docs/tools page
- [ ] Keep the overflow→file+jq fallback (praised in #19) — do not regress

---

## #16 — Hot restart spawns a new session; no stable app identity  ·  Feature · medium-large

**Status: OPEN.** Sessions are keyed purely by `vmServiceUri`
(session.dart:140). Each hot restart = new VM URI = new `sessionId`; dead
sessions stay listed as "attached." NB: this is **distinct from** the
0.7.3 continuation work (that's cross-conversation reattach; this is
within-session migration across restarts).

- [ ] Virtual app-session identity keyed on `(package, device)` that
      wraps successive VM URIs and keeps `sessionId` stable across restarts
- [ ] Detect VM URI change on hot restart → migrate under the hood → mark
      the old URI dead and drop it from `attached` automatically
- [ ] `network_status.attached[].lastReattachAt` to surface a migration
- [ ] **MVP that covers ~90%:** `network_attach{appNameContains, reattach:true}`
      — find the current URI for that app, reattach, kill the stale session
- [ ] Test: simulate a URI change; assert `sessionId` stability + stale drop

---

## #17 — Silent capability degradation on reattach  ·  BUG/UX · partially done

**Status: SHIPPED in 0.8.0** (structured `capabilities`/`degraded` on attach +
per-session `network_status`).

- [x] `socket_*` tools now return a structured error (not an empty array)
      when socket profiling is unavailable (socket_list.dart:94,
      socket_get.dart:70) — the core "soft fail" complaint is addressed
- [ ] Structured per-session `capabilities:{http:"ok",socket:"unavailable",
      logs:"ok"}` block in the **attach** response — today degradation
      lives only in `warnings` + a flat `socketProfilingEnabled` bool
      (network_attach.dart:303-355), which the reporter (correctly) says
      gets scanned past
- [ ] `degraded:[...]` array in the attach response + each
      `network_status.attached[]` entry
- [ ] `network_status.capabilities` (network_status.dart:85) currently
      reports globally-**enabled categories**, not per-session **runtime
      health** — add a per-session runtime view distinct from the global one
- [ ] Optionally re-run capability enablement on each attach; report
      `degraded:[]` in steady state

---

## #18 — Wishlist: live tail / log↔network correlation / sticky filters  ·  Feature

**Status: mostly OPEN; one part is a deliberate non-goal.**

- ~~Live tail subscription (`logs_subscribe` + push notifications)~~ —
  **NON-GOAL.** MCP has no server-initiated push; documented in
  `FUTURE_FEATURES.md` ("Real-time streaming to the agent"). Polling
  (`alerts_drain` pattern) stays.
- [ ] **log↔network correlation** — new `correlate_at(timestampMs, windowMs)`
      returning logs + HTTP in one shot, OR `nearbyRequests:[{id,deltaMs}]`
      on each `logs_tail` entry. (Distinct from the existing
      `network_correlate`, which matches requests *across sessions*.)
- [ ] **sticky filters** — `session_open` / new `session_configure` gains
      `defaultFilters` that subsequent `logs_tail` / `network_list` reads
      inherit unless overridden
- [ ] Decide: bundle correlation + sticky as one "interactive debugging"
      release; live-tail stays parked in `FUTURE_FEATURES.md`

---

## #19 — Positive feedback  ·  no fix, convert to guards

**Status: acknowledge.** Things that worked: `nextSteps` everywhere,
`pendingAlerts.count` on every response, the overflow→file+jq escape
hatch, replay/diff in `nextSteps`, transparent multi-attach. Lock them
in so we don't regress.

- [ ] Reply on the issue thanking + confirming these are now invariants
- [ ] (optional) Lightweight regression guards: every tool response carries
      `nextSteps`; `pendingAlerts.count` present on read responses; the
      overflow escape hatch fires above the cap

---

## #20 — Make the `instructions` field give agents concrete triggers + a script  ·  Meta

**Status: PARTIALLY FIXED.**

- [x] Auto `agent-filed` label on agent-filed issues — done in 0.7.2
      `report_issue` (`_labelsForType`, report_issue.dart:159-161:
      bug→`[bug,agent-filed]`, ux→`[ux-friction,agent-filed]`)
- [ ] Rewrite the server `instructions` field (server.dart:58-76) to add
      concrete **triggers** (user-friction phrases, a tool error +
      workaround, session end) + a pre-written **offer script** +
      "once per conversation max" + "concrete repro only" (the reporter
      supplied exact wording in the issue — adopt it)
- [ ] (optional, higher effort) `mcp_feedback_offer` deferred tool with
      `{trigger, context}` — both nudges the agent and gives a funnel
      metric (offered vs accepted)
- [ ] Mirror the trigger/script guidance into `docs/README.md` for
      discoverability

---

## #21 — Configurable log ring buffer  ·  UX · partially done

**Status: PARTIALLY FIXED.**

- [x] Env-var configurable buffer — done: `FLUTTER_NETWORK_MCP_LOG_BUFFER`
      (default 500, clamped 50–10000), log_buffer.dart:48
- [ ] Naming mismatch: the issue asked for `FLUTTER_NETWORK_MCP_LOG_BUFFER_SIZE`;
      either accept both names (alias) or document the actual one
- [ ] **Bug found during triage:** the "near capacity" warning is
      hardcoded to `/ 500` with a `>= 480` threshold (logs_tail.dart:229-230),
      and the tool description says "capacity 500" (logs_tail.dart:23) —
      both are wrong when the env override is set. Make them read the real
      capacity.
- [ ] Surface `logBufferCapacity` + `logBufferUsed` (+ optional rotation
      rate) in `network_status.attached[]`
- [ ] Per-attach override: `network_attach{logBufferSize:N}` (today
      `LogBuffer()` reads env only, network_attach.dart:215)
- [ ] `nextSteps` hint when the buffer is >80% full on a `logs_tail` return

---

## Roll-up: what the unmerged stack already closed

| Issue | Already in stack | Still open |
|---|---|---|
| #13 | — | full (root cause: backfill gate) |
| #14 | ambiguity/no-match errors (single-DTD) | multi-DTD resolution + wording |
| #15 | — | `messageContains` |
| #16 | — | full (hot-restart identity) |
| #17 | `socket_*` error instead of empty | structured `capabilities`/`degraded` |
| #18 | — | correlation + sticky (live-tail = non-goal) |
| #19 | the praised behaviors already exist | convert to guards |
| #20 | `agent-filed` label (0.7.2) | instructions triggers/script |
| #21 | env-var buffer | naming, surfacing, per-attach, hardcoded-500 bug |

## Open questions for the maintainer

1. Sequencing OK (0.8.0 bugs → 0.8.1 quick wins → 0.8.2 #16 → backlog #18)?
2. #16: ship the full virtual-identity migration, or land the
   `reattach:true` MVP first and defer auto-migration?
3. #20: just rewrite the `instructions` text, or also build the
   `mcp_feedback_offer` deferred tool?
4. Should I post acknowledgement comments on each issue (esp. #19), or
   leave the threads until the fixes land?
