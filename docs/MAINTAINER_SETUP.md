# Maintainer setup for the 0.7.x roadmap

> Audience: the maintainer (Lukas-io). This doc walks you through the
> setup steps + decisions that unblock the 0.7.x release line. Most
> items are 5-minute decisions. The one external-account item is
> Cloudflare (free tier, ~30 minutes one-time).
>
> Work through this at your pace. The agent shipping the roadmap
> doesn't need everything at once — items are flagged with the
> release that consumes them. You can defer the Cloudflare work
> until 0.7.1 if you want; 0.7.0 needs nothing from you.

## Table of contents

- [Roadmap recap](#roadmap-recap) — what's shipping when
- [Decision checklist](#decision-checklist) — copy-paste this back to me
- [Crash telemetry collector (0.7.1)](#crash-telemetry-collector-071) — Cloudflare Worker + D1
- [HMAC salt (0.7.1)](#hmac-salt-071) — approval only
- [`report_issue` auto-filing (0.7.2)](#report_issue-auto-filing-072) — gh CLI scope
- [`setup` wizard (0.7.4)](#setup-wizard-074) — MCP host targets
- [WS/gRPC investigation (0.8.0)](#wsgrpc-investigation-080) — acceptance criteria

---

## Roadmap recap

| Release | Features | What you need to provide |
|---|---|---|
| **0.7.0** | Semantic body truncation · `network_summarize` | Nothing |
| **0.7.1** | Crash telemetry (default-on + audit log) | Cloudflare URL (or "ship local-only") + HMAC salt approval |
| **0.7.2** | `report_issue` auto-filing · Pattern memory | `gh` CLI policy + label conventions |
| **0.7.3** | Anomaly alerts · Session continuation | Nothing |
| **0.7.4** | Writable auto-attach config · `setup` wizard | MCP host targets |
| **0.8.0** | WebSocket + gRPC frame capture | Acceptance of investigation-first commit |

---

## Decision checklist

Reply with this filled in whenever you've made the decisions — I'll
read it back into the relevant PR. Each item is also detailed in the
sections below.

```
## Decisions

# Crash telemetry collector (0.7.1):
[ ] A — Deploy Cloudflare Worker + D1 now (URL: ___)
[ ] B — Ship local-only first, defer collector

# HMAC salt:
[ ] Generate a 32-byte hex salt and bake it into 0.7.1

# report_issue (0.7.2):
[ ] gh CLI only
[ ] gh CLI + $GITHUB_TOKEN env-var fallback
Labels to auto-apply on filed issues:
  - For bug reports: ___
  - For UX friction: ___

# setup wizard (0.7.4) — which MCP hosts to support:
[ ] Claude Code only
[ ] + Cursor
[ ] + Windsurf
[ ] + Zed
[ ] Other: ___

# WS/gRPC (0.8.0):
[ ] OK if the first PR commit is investigation findings (even if the
    conclusion is "this needs a different architecture")
[ ] No — only ship when feature works end-to-end
```

---

## Crash telemetry collector (0.7.1)

Pick one of two paths.

### Path A: Deploy the collector now (~30 min)

Free tier handles 100K writes/day. Total cost: $0/month at any
reasonable scale.

#### Step 1: Sign up for Cloudflare

1. Go to <https://dash.cloudflare.com/sign-up>.
2. Create an account with `wisdomiyamu@gmail.com` (or whatever email
   you want owning the collector).
3. Verify your email.

#### Step 2: Install Wrangler (Cloudflare's deploy CLI)

```bash
npm install -g wrangler
# Verify:
wrangler --version
# Login:
wrangler login
# Opens a browser. Approve.
```

If you don't have npm: install Node.js from <https://nodejs.org/>
(LTS version is fine).

#### Step 3: Create the D1 database

```bash
mkdir -p ~/code/flutter_network_mcp_collector && cd $_
wrangler d1 create flutter-network-crashes
```

Wrangler will print a `database_id` like
`abc12345-6789-...`. Save it; you'll paste it into `wrangler.toml` in
the next step.

#### Step 4: Drop in the Worker code

I'll provide a complete `worker.js` + `wrangler.toml` + `schema.sql`
in the PR that ships crash telemetry (0.7.1). For now, here's the
structure so you know what's coming:

```
flutter_network_mcp_collector/
├── wrangler.toml      # Cloudflare config (paste your account_id + database_id here)
├── src/worker.js      # POST /v1/crashes handler — ~80 lines
└── schema.sql         # D1 schema (crashes table)
```

The 0.7.1 PR will include these files in a `collector/` subdirectory
of the main repo. You'll copy them to your collector dir, edit
`wrangler.toml` with your IDs, and deploy.

#### Step 5: Deploy

```bash
# Apply schema:
wrangler d1 execute flutter-network-crashes --file=schema.sql

# Deploy Worker:
wrangler deploy
# Prints the URL: https://flutter-network-crashes.<your-subdomain>.workers.dev
```

#### Step 6: Send me back

Reply with:
```
COLLECTOR_URL: https://flutter-network-crashes.<your-subdomain>.workers.dev/v1/crashes
```

I bake this into 0.7.1 as `kCollectorEndpoint`. The MCP POSTs to
that URL on every uncaught error (when telemetry is enabled — opt-out
via `FLUTTER_NETWORK_MCP_NO_TELEMETRY=true`).

#### Step 7: Verify (optional)

After 0.7.1 ships and you've upgraded your local install:

```bash
# Force a crash via a test endpoint:
flutter_network_mcp --test-telemetry  # (subcommand I'll add for this)

# Read what got recorded:
flutter_network_mcp audit show --since 1m

# Verify the D1 table:
wrangler d1 execute flutter-network-crashes --command="SELECT signature, COUNT(*) FROM crashes GROUP BY signature"
```

### Path B: Ship local-only first

If you'd rather defer the Cloudflare work: the binary writes the
tamper-evident audit log at `<data-dir>/telemetry-audit.log` but
the POST is stubbed (drops silently). The trust pact still works
locally; just no central collection until you deploy.

Choose this if:
- You don't want a Cloudflare account right now.
- You want to validate the audit-log + verify commands first before
  exposing a collector.
- You want to ship 0.7.1 sooner.

Conversion path: deploy the Worker later (the steps above), I ship
a 0.7.1.1 patch that flips the endpoint from stub to real.

### What's NOT in the payload (security review)

Same constraints regardless of path:

- No `$HOME`, no `cwd`, no project path
- No vmServiceUri / DTD URI / connection token
- No captured HTTP bodies, headers, URLs
- No env var contents
- No `captures.db` row contents

The path redactor (shared with the `report_issue` tool in 0.7.2)
strips `/Users/<name>/` → `<home>/`, `StudioProjects/<x>/` →
`<project>/`, etc. before anything goes on the wire.

The local audit log uses the same redactor — what you see in
`audit show` is byte-for-byte what hit (or would have hit) the
collector.

---

## HMAC salt (0.7.1)

The collector uses `machine_hash = HMAC_SHA256(data_dir_path,
public_salt)[:24]` to dedupe machines without learning anything
identifying. The collector knows the salt; the salt is baked into the
binary at compile time.

Two things baked:
- **Public salt** — visible in the binary, used by every install to
  compute its machine_hash.
- **HMAC secret** — held only by you (on the Cloudflare side), used to
  verify incoming payloads if we add auth later. Optional for v1.

### Approval

Reply with:
```
[ ] Generate a 32-byte hex salt and bake it into 0.7.1
```

I'll generate it via `openssl rand -hex 32` and include it as a
constant in `lib/src/telemetry/telemetry_constants.dart`. You hold
the corresponding secret if/when we add auth later.

---

## `report_issue` auto-filing (0.7.2)

This tool lets agents file GitHub issues with one call. Two decisions.

### gh CLI scope

**Recommendation: gh CLI only.**

The user (the one running the MCP) authenticates `gh` once via
`gh auth login`. The MCP shells out to `gh issue create` with the
composed body. No tokens stored, no API plumbing.

If `gh` isn't installed, the tool returns a paste-ready body the
user can paste into the GitHub UI manually.

Reply with:
```
[ ] gh CLI only (recommended)
[ ] gh CLI + $GITHUB_TOKEN env-var fallback for users without gh
```

The fallback adds ~50 LOC + a new env-var contract. Skip if you don't
have users explicitly asking for it.

### Issue labels

When the tool files an issue, it can auto-apply labels for triage.
The two issue templates today are `bug_report.md` and
`ux_friction.md`. Reply with what to apply:

```
For bug reports: [bug, agent-filed]
For UX friction: [ux-friction, agent-filed]
```

(Defaults shown — adjust to match your existing label conventions on
the repo. The `agent-filed` label lets you grep for auto-filed issues
vs. human-filed.)

---

## `setup` wizard (0.7.4)

Interactive subcommand that detects the MCP host and scaffolds the
config. Pick which hosts to support.

| Host | Config path | Priority |
|---|---|---|
| Claude Code | `~/.claude.json` and project-level `.mcp.json` | ✓ Must-have |
| Cursor | `~/.cursor/mcp.json` | Nice-to-have |
| Windsurf | `~/.windsurf/mcp_config.json` (path TBC) | Optional |
| Zed | `~/.config/zed/settings.json` (inside `mcp_servers` key) | Optional |

Reply with:
```
[ ] Claude Code only
[ ] + Cursor
[ ] + Windsurf
[ ] + Zed
[ ] Other (specify path conventions): ___
```

Claude Code only is fine for v1 — adoption by other host users will
tell us what to add. Adding more hosts is ~30 LOC per host (just
path resolution + config schema).

---

## WS/gRPC investigation (0.8.0)

This is the biggest scope item in the roadmap and has unknowns. The
Dart HTTP profiler ends at the WebSocket upgrade handshake; frame-
level capture may require:

- A separate VM service stream subscription (if one exists)
- IOOverrides instrumentation injected at app startup
- A proxy-mode capture model (intercepting at the network layer, not
  VM layer)
- Or it may not be possible without changes to the Dart SDK itself

### Acceptance criteria

I'd ship a small "investigation" commit BEFORE the feature work,
exploring what's actually possible. The PR description will include
findings: what streams exist, what data they expose, what the
implementation cost looks like.

Three possible outcomes:
1. **Feature ships end-to-end.** Full WS + gRPC capture as designed,
   four new tools, schema bump to v8.
2. **Partial.** WS works but gRPC doesn't (or vice versa); the PR
   ships what works + a note explaining what's blocked.
3. **Architecture proposal.** Neither works in the current model;
   the PR ships a design proposal for an alternative (e.g. proxy
   mode) for the next release line.

Reply with:
```
[ ] OK if the first PR commit is investigation findings, even if the
    outcome is option 3 (architecture proposal, no working feature)
[ ] No — only ship 0.8.0 when the feature works end-to-end
```

If you pick "no," 0.8.0 will slip until the investigation produces
a working path. Per the accuracy-over-speed reminder, that's fine —
shipping a half-working feature is worse than slipping.

---

## What I'll deliver back to you per release

| Release | Deliverable in addition to code |
|---|---|
| 0.7.0 | Standalone PR; nothing extra needed |
| 0.7.1 | If path A: complete `collector/` directory in the PR with `worker.js` + `wrangler.toml` + `schema.sql`. Verification script. |
| 0.7.2 | Doc updating `report_issue` behavior. Sample `gh issue create` invocation. |
| 0.7.3 | New `endpoint_stats` schema doc. Sample `network_status.continuation` block. |
| 0.7.4 | `setup` wizard demo recording (terminal capture, no audio). |
| 0.8.0 | Investigation findings doc regardless of outcome. |

---

## When to read this doc again

- Before deploying the Cloudflare collector (Step 1 of crash telemetry path A).
- When the 0.7.1 PR opens (verify the `collector/` files match the schema described here).
- When the 0.7.4 PR opens (cross-check the `setup` wizard's host coverage against your decision).
- When the 0.8.0 PR opens (review the investigation findings — your call on what ships).

If anything in here is unclear or doesn't match what you want, push
back via PR comments on this doc. It's easier to revise the spec
than the code.
