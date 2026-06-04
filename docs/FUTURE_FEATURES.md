# Future features (backlog)

> Honorable-mention list from the 0.7.x roadmap planning round. Each
> entry was considered for the top-10 cut, weighed against impact /
> scope / proximity to existing capabilities, and parked here for
> reconsideration when the 0.7.x line wraps (post-0.7.4).
>
> By then we'll have signal from real agent usage telling us which
> of these promoted themselves naturally — bugs people kept hitting,
> features they kept asking for, gaps the top-10 didn't close.

## Reconsideration trigger

Re-evaluate this list at the **post-0.7.4 retrospective**. At that
point we'll have:
- ~5 weeks of telemetry data (if the collector is live)
- Real agent-filed issue reports via `report_issue`
- User feedback on the `setup` wizard adoption
- Pattern-memory hit rates showing which recurring bugs people see

Use that data to:
1. Promote 0–3 backlog items into the 0.8.x line.
2. Drop items that no longer match user need.
3. Add new items surfaced by telemetry/issues that don't appear here.

## Backlog

### 1. Session replay → test scaffold

**What.** `network_replay_as_test sessionId:14 endpoint:"/api/login"`
generates a runnable Dart test that hits the same endpoint with the
captured headers + body, asserts the same status code + body shape.
Agent can iterate the test instead of re-running the user's app.

**Why parked.** Powerful but narrow audience — only useful for people
writing automated tests against captured sessions. Most debugging
turns are one-shot, not "let me build a test from this." Re-promote if
multiple users ask for it.

**Effort.** M. **Depends on.** `network_replay` (shipped).

### 2. Smart capture polling

**What.** Adapt the 2-second `CaptureWriter` poll interval to traffic
volume: quiet apps poll every 5s, chatty apps every 500ms. Reduces
overhead without losing fidelity.

**Why parked.** Real efficiency win but **invisible to the agent.**
Doesn't change any tool output, doesn't change any conversation. Bumps
to the top only if someone reports the 2s default is causing problems
in real apps.

**Effort.** S. **Depends on.** Nothing.

### 3. Per-endpoint redaction rules

**What.** Today `redacted_headers` is global. Add per-host / per-path
rules: "`Authorization` on `/api/login` → redact; `Authorization` on
`/api/health` → leave."

**Why parked.** Real privacy feature but narrow — most users don't
have endpoints they specifically don't want redacted. The global rule
covers 95% of cases. Promote if a user reports a real workflow
blocked.

**Effort.** S. **Depends on.** `redacted_headers` (shipped).

### 4. Investigation snapshots

**What.** `snapshot save name:"login-broken"` serializes the current
investigation state (attached sessions, drained alerts, viewed
requests, session_open pointer). `snapshot restore name:"login-broken"`
brings it back. Cross-conversation continuity.

**Why parked.** Overlaps significantly with session continuation
memory (#6 in the top-10). If continuation isn't enough, this fills
the gap; if it is, this is redundant. Wait for post-0.7.3 to decide.

**Effort.** M. **Depends on.** Session continuation memory (0.7.3).

### 5. Network condition simulation

**What.** Proxy-mode capture that can throttle, drop, or delay
specific endpoints. Test how the app handles `/api/login` at 3G
speeds or with intermittent failures without going outside.

**Why parked.** Moves into **capture-modification**, a much larger
architectural scope than the current read-only model. The MCP becomes
an active participant in the app's network, not just a reader. Would
need a different security review.

**Effort.** L. **Depends on.** Major architectural decision.

### 6. Time-travel debugging

**What.** `network_at tsMs:1780462000000` returns app state (open
requests, recent logs, attached isolates) as of a specific moment.
Useful for "what was happening when the user clicked X."

**Why parked.** Cool but agents rarely need exact-time precision —
they tend to work in "last 5 minutes" or "since session start"
windows that `since` cursors already cover. Promote if pattern
memory (#9 in top-10) reveals that recurring bugs cluster around
specific moments.

**Effort.** M. **Depends on.** Nothing.

### 7. Live-vs-history session diff

**What.** `network_diff_session live vs sessionId:42` shows what
changed broadly: new endpoints, gone endpoints, status distribution
shifts. The "what's different about today's run" view.

**Why parked.** Niche — handled today by `network_query` SQL with a
bit of effort. Promote into the typed tool surface only if SQL
ergonomics turn out to be a barrier for the common case.

**Effort.** S. **Depends on.** Nothing.

## What's NOT here and why

Some things were considered AND rejected (not just deferred) — listed
here so future-you doesn't re-propose them without revisiting the
reasoning.

### More HTTP-specific drill-down tools

The HTTP surface (`list` / `get` / `body` / `search` / `diff` /
`replay` / `query`) is saturated. Adding more splits agent attention
without adding new capability. Future HTTP work should refine existing
tools, not multiply them.

### A web UI for browsing captures

Out of scope. **The agent IS the UI for this product.** A web UI
creates a different surface area (auth, hosting, mobile responsive,
etc.) that competes with the agent-first focus.

If a web UI is genuinely useful later, it should be a separate
project that reads the same `captures.db`.

### Real-time streaming to the agent

MCP doesn't support server-initiated push. Emulating it via tool
polling already works (`alerts_drain` pattern, daily `update_check`).
Adding real streaming would require an MCP protocol change.

### Auto-fix suggestions for detected bugs

The MCP **surfaces** state; the agent **reasons** about it. Putting
auto-fix in the MCP duplicates what the agent already does well and
makes the MCP an active code-modifier — different threat model, much
larger blast radius.

The MCP can report "this request failed with 401"; the agent decides
that means "your auth token expired" and proposes a fix. Don't blur
that line.

---

## How to read this doc

This is a **parking lot**, not a roadmap. None of these items has a
commitment to ship. The 0.7.x roadmap in the plan file ships first;
this backlog gets revisited after.

When you reconsider, do it as a new planning round (not by editing
this doc piecemeal):
1. Read this doc + the post-0.7.4 telemetry data.
2. Pick 0–3 items to promote into the 0.8.x line.
3. Update the relevant plan file with the new roadmap.
4. Remove promoted items from this doc; add new backlog items.

That keeps this doc honest as a "stuff we explicitly chose NOT to do
yet" record, not a wishlist.
