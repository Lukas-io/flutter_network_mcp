# flutter_network_mcp telemetry collector

A single Cloudflare Worker + D1 database that receives the two payload kinds the MCP binary ships to `kCollectorEndpoint`:

- **usage rollups** (issue #79): per-tool counts, outcome + latency stats, and the tool→next-tool transition graph. This is the "how are agents using the tools?" data.
- **crash reports** (0.7.1): anonymized uncaught-error reports.

Both are keyed by `machine_hash` (a one-way HMAC per install). No PII, URLs, bodies, or arg values are ever sent; see [`docs/CRASH_REPORTING.md`](../docs/CRASH_REPORTING.md).

## Files

- `schema.sql`: D1 tables `crashes`, `usage_rollups`, `tool_stats`, `tool_transitions`, `tool_error_kinds`.
- `migrations/`: incremental D1 migrations for already-deployed collectors.
- `src/worker.js`: `POST /v1/telemetry` (routes by `kind`), `GET /v1/stats` (quick per-tool JSON), `GET /` (health).
- `wrangler.toml`: config; paste your `database_id`.

## Deploy (~10 min, all from this `collector/` directory)

```bash
# 0. one-time: install + login (already done if you followed the walkthrough)
npm install -g wrangler
wrangler login

# 1. create the D1 database (prints a database_id)
wrangler d1 create flutter-network-telemetry

# 2. paste that database_id into wrangler.toml (the database_id = "..." line)

# 3. apply the schema (remote D1, not the local emulator)
wrangler d1 execute flutter-network-telemetry --remote --file=schema.sql

# 4. deploy the Worker (prints https://flutter-network-telemetry.<subdomain>.workers.dev)
wrangler deploy
```

Then send the maintainer agent:

```
COLLECTOR_URL: https://flutter-network-telemetry.<subdomain>.workers.dev/v1/telemetry
```

It gets baked into `lib/src/telemetry/telemetry_constants.dart` (`kCollectorEndpoint`) in a patch release, and installs start POSTing (opt-out stays `FLUTTER_NETWORK_MCP_NO_TELEMETRY=true`).

## Seeing the data (the event-tracking payoff)

Quick glance, no SQL:

```bash
curl https://flutter-network-telemetry.<subdomain>.workers.dev/v1/stats
```

Per-tool usage across all installs:

```bash
wrangler d1 execute flutter-network-telemetry --remote --command \
  "SELECT tool, SUM(count) AS calls, SUM(error) AS errors, SUM(empty) AS empties
     FROM tool_stats GROUP BY tool ORDER BY calls DESC"
```

The playbook agents actually follow (busiest transitions):

```bash
wrangler d1 execute flutter-network-telemetry --remote --command \
  "SELECT from_tool, to_tool, SUM(count) AS n FROM tool_transitions
     GROUP BY from_tool, to_tool ORDER BY n DESC LIMIT 20"
```

Tools with the worst error rate (candidates to fix or document better):

```bash
wrangler d1 execute flutter-network-telemetry --remote --command \
  "SELECT tool, SUM(error)*1.0/SUM(count) AS error_rate, SUM(count) AS calls
     FROM tool_stats GROUP BY tool HAVING calls > 10 ORDER BY error_rate DESC"
```

Most common crashes by signature:

```bash
wrangler d1 execute flutter-network-telemetry --remote --command \
  "SELECT signature, error_class, COUNT(*) AS n FROM crashes
     GROUP BY signature ORDER BY n DESC LIMIT 20"
```

## Tier-1 datapoints (error composition, context cost, degradation)

Apply the migration to an existing deployment once, then re-deploy the worker:

```bash
wrangler d1 execute flutter-network-telemetry --remote --file=migrations/001-tier1-datapoints.sql
wrangler deploy
```

**WHY a tool errors, not just how often** — the signal that turns "tool X errors a lot" into an action. `bad_argument`-heavy = your schema/docs confuse agents (you fix it); `unresponsive_vm` = infra; `not_found` = agents reuse stale ids:

```bash
wrangler d1 execute flutter-network-telemetry --remote --command \
  "SELECT tool, error_kind, SUM(count) AS n FROM tool_error_kinds
     GROUP BY tool, error_kind ORDER BY n DESC LIMIT 30"
```

**Context cost ranking** — which tools eat the most of the agent's window:

```bash
wrangler d1 execute flutter-network-telemetry --remote --command \
  "SELECT tool, SUM(estimated_tokens) AS tokens, SUM(count) AS calls
     FROM tool_stats GROUP BY tool ORDER BY tokens DESC"
```

**Live-path reliability** — how often a tool falls back from live to the DB snapshot (high = the live read is flaky there):

```bash
wrangler d1 execute flutter-network-telemetry --remote --command \
  "SELECT tool, SUM(degraded) AS degraded, SUM(count) AS calls,
          SUM(degraded)*1.0/SUM(count) AS degrade_rate
     FROM tool_stats GROUP BY tool HAVING degraded > 0 ORDER BY degrade_rate DESC"
```

## Cost

Cloudflare free tier: 100K D1 writes/day + 100K Worker requests/day. A rollup ships at most once/day per install, so this stays free well past thousands of installs.

## Notes

- v1 has no auth. The only identifier is the one-way `machine_hash`; payloads carry nothing sensitive. If abuse appears, add a shared-secret header check in `worker.js` (the binary holds the public salt; you hold the HMAC secret here).
- The worker accepts the rollup/crash shapes as built by `UsageReporter.buildUsagePayload` and `buildTelemetryPayload`. If those payloads change, update `schema.sql` + the INSERTs together.
