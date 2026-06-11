# Tool reference for agents

Per-tool guidance for `flutter_network_mcp`. Tools are organized in `tools/<category>/` subfolders — each folder has a `README.md` that lists its tools, and each tool has its own page with a **DO NOT USE THIS TOOL WHEN** section at the top. Negative flags catch ~70% of misuse before it happens; read them first.

The index below is by **use case** ("I want to do X — which tool?"). Some tools serve more than one job and appear under more than one section; the physical file lives in its primary category folder. The [capability matrix](#capability-matrix) at the bottom maps tools to the `--capabilities` / `--disable` startup flags.

> **Filing issues is agent-first.** When something breaks or feels off in this MCP — wrong output, missing field, slow, confusing, awkward — open an issue at https://github.com/Lukas-io/flutter_network_mcp/issues. Two templates, both dead simple: **"Bug report"** for code issues (3 fields — what broke, the failing tool call, the `network_status` response; optional context collapses), **"UX friction / suggestion"** for anything that just felt awkward (3 fields, no environment needed). Use a GitHub tool if you have one; otherwise hand the user a paste-ready body. Don't wait for the user to ask. Big or small, code or UX — every report helps.

> **Multi-attach (0.6.0):** the server can hold N concurrent attached sessions (capped via `FLUTTER_NETWORK_MCP_MAX_ATTACH`, default 4). Every read tool accepts an optional `sessionId:int` or `appNameContains:string`. With exactly one session attached the tool auto-resolves and no scope arg is needed. With 2+ attached and no scope, tools error with a structured `attached:[...]` list + `nextSteps` like `sessionId:14  // sanga_mobile`. Successful responses include a `scope:{sessionId, appName, isLive}` block so you can verify which session you just read from. `pendingAlerts` auto-injection is scoped per-session — no cross-app data bleed in the push-like signal. `network_status.attached` is now a list, `network_detach` takes `sessionId` / `appNameContains` / `all:true`.

> **Multi-isolate within one app (0.6.0):** captures HTTP/socket/log traffic from EVERY isolate in the attached app (was: only the first). Per-row `isolate_id` tagging via schema v4. The 11 read tools that take `sessionId:` also accept an optional **`isolateId:`** filter (omit to merge every isolate — single-isolate UX preserved). `network_status.attached[].isolates` lists what's being captured. Newly-spawned isolates get picked up automatically on a ~20s re-scan.

> **Cross-app correlate (0.6.0):** the new `network_correlate` tool finds matching requests across 2+ attached sessions by a shared substring (webhook id, correlation token, URL fragment). Requires explicit `sessionIds:[int]` — cross-session aggregation is intentional. Use case: sanga_mobile sends a webhook, sanga_driver receives it; this returns both halves paired by smallest time delta.

---

## Use cases

### [Getting started — first call of any session](tools/lifecycle/)
- [`network_status`](tools/lifecycle/network_status.md) — what's reachable, what's pending, what's enabled. Auto-connects DTD.
- [`network_discover_dtd`](tools/lifecycle/network_discover_dtd.md) — list DTDs on this machine from the standard `package:dtd` directory. Useful when multiple `flutter run` instances are active or when startup auto-discovery picked the wrong one (0.6.2+).
- [`network_attach`](tools/lifecycle/network_attach.md) — open a capture session against a running app.
- [`report_issue`](tools/lifecycle/report_issue.md) — file a GitHub issue against this MCP from inside an agent turn. `gh` CLI or paste-ready URL fallback (0.7.2+).
- [`auto_attach_config`](tools/lifecycle/auto_attach_config.md) — persist auto-attach allowlist changes from agent + user confirmation; closes the `mcp remove/add` cycle (0.7.4+).

### [Finding a request](tools/finding/)
- [`network_list`](tools/finding/network_list.md) — by metadata (host, method, status, time). Cursor-based.
- [`network_search`](tools/finding/network_search.md) — by content (text in url or body). BM25-ranked.
- [`network_summarize`](tools/finding/network_summarize.md) — one digest row per endpoint (count, statusDist, p50/p95, errorRate). Cheaper than `network_list` for shape-of-session orientation (0.7.0+).

### [Inspecting one request](tools/inspecting/)
- [`network_get`](tools/inspecting/network_get.md) — full headers + truncated body for one id.
- [`network_body`](tools/inspecting/network_body.md) — byte-range fetch when `network_get` reports `truncated:true`.

### [Comparing or reproducing requests](tools/comparing/)
- [`network_diff`](tools/comparing/network_diff.md) — structural diff of two captured requests.
- [`network_replay`](tools/comparing/network_replay.md) — emit a runnable curl command (auth headers redacted by default).

### [Surfacing "what went wrong"](tools/what-went-wrong/)
- [`alerts_drain`](tools/what-went-wrong/alerts_drain.md) — read AND clear pending alerts. Per-severity breakdown.
- [`alerts_peek`](tools/what-went-wrong/alerts_peek.md) — read without clearing.
- [`logs_tail`](tools/what-went-wrong/logs_tail.md) — recent log/stdout/stderr records.
- [`correlate_at`](tools/what-went-wrong/correlate_at.md) — logs + HTTP requests within ±windowMs of an anchor timestamp, nearest-first. "Which request fired closest to this log line?" (0.8.3+).

### [Investigating history](tools/history/)
- [`session_list`](tools/history/session_list.md) — past capture sessions with counts.
- [`session_open`](tools/history/session_open.md) — point read tools at a past session.
- [`session_close`](tools/history/session_close.md) — revert read pointer to live.
- [`session_export`](tools/history/session_export.md) — write HAR / NDJSON to disk.
- [`session_note`](tools/history/session_note.md) — freeform note on a session.

### [Tuning what gets captured & analyzed](tools/tuning/)
- [`alerts_config`](tools/tuning/alerts_config.md) — toggle alert rules; set the slow-request threshold.
- [`alert_patterns`](tools/tuning/alert_patterns.md) — add project-specific regex patterns.
- [`ignored_hosts`](tools/tuning/ignored_hosts.md) — drop analytics/telemetry at capture time.
- [`redacted_headers`](tools/tuning/redacted_headers.md) — extend `network_replay`'s redaction set.

### [Resetting live state (does NOT touch the DB)](tools/reset-live/)
- [`network_clear`](tools/reset-live/network_clear.md) — wipe live HTTP profile.
- [`socket_clear`](tools/reset-live/socket_clear.md) — wipe live socket profile.
- [`logs_clear`](tools/reset-live/logs_clear.md) — empty live log buffer.
- [`alerts_clear`](tools/reset-live/alerts_clear.md) — delete drained alerts from DB (safe-by-default).

### [Managing the persistent DB](tools/db-management/)
- [`db_stats`](tools/db-management/db_stats.md) — file size, row counts, body bytes.
- [`bodies_purge`](tools/db-management/bodies_purge.md) — drop BLOBs, keep metadata. Dry-run by default.
- [`session_delete`](tools/db-management/session_delete.md) — permanently remove a session. Dry-run by default.
- [`db_vacuum`](tools/db-management/db_vacuum.md) — reclaim disk space after the above. Run last.

### [Sockets (non-HTTP traffic)](tools/sockets/)
- [`socket_list`](tools/sockets/socket_list.md) — TCP/UDP byte counts + lifetimes.
- [`socket_get`](tools/sockets/socket_get.md) — one socket's detail.

### [Power user / ad-hoc queries](tools/power/)
- [`network_query`](tools/power/network_query.md) — read-only SQL escape hatch (BLOB-safe, cell-capped, 500-row cap).
- [`network_correlate`](tools/power/network_correlate.md) — find matching requests across 2+ sessions (webhook originator + receiver pattern). Requires explicit `sessionIds:[int]`.

### Wrapping up (in `lifecycle/`)
- [`network_detach`](tools/lifecycle/network_detach.md) — close the live session. Captured data stays queryable.

---

## Investigation playbook

A typical agent turn through the use cases above:

1. `network_status` first. If `alerts.pendingTotal > 0` (or `critical > 0`), call `alerts_drain`.
2. If the user described a symptom in plain language ("auth failed"), `network_search query="<the words>"`.
3. If they referenced a past session, `session_list` then `session_open`.
4. Found a candidate request? `network_get` for full detail; `network_body` for byte ranges if `truncated:true`.
5. Need to compare two requests? `network_diff`.
6. Want to reproduce a request from the terminal? `network_replay`.
7. Filing a bug for a coworker? `session_export id=<n> format=har`.
8. Done? `network_detach`.

---

## Context-budget rules (the server enforces these)

- **Summary tools never return bodies.** They give sizes; you fetch bodies on demand via `network_get` / `network_body`.
- **Hard caps on every list/range tool.** Default 50, max 200 for HTTP lists. Bodies: default 4 KB truncated, max 256 KB per byte-range call.
- **Cursors everywhere.** Don't refetch — pass `since` / `nextCursor`.
- **Server-side filtering.** Use `method`, `hostContains`, `statusMin/Max`, `levelMin`, `loggerContains` before pulling bodies.
- **Every response is `{summary, ..., nextSteps, [warnings]}`** — branch on these instead of re-asking the server. Errors follow the same shape.

---

## Capability matrix

For `--capabilities` / `--disable` startup flags — the tools each capability gates:

| Capability | Tools |
|---|---|
| `http` | `network_list`, `network_get`, `network_body`, `network_clear`, `network_diff`, `network_replay` |
| `sockets` | `socket_list`, `socket_get`, `socket_clear` |
| `logs` | `logs_tail`, `logs_clear` |
| `alerts` | `alerts_drain`, `alerts_peek`, `alerts_config`, `alerts_clear`, `alert_patterns` |
| `search` | `network_search` |
| `sessions` | `session_list`, `session_open`, `session_close`, `session_export`, `session_note`, `session_delete` |
| `sql` | `network_query` |
| `admin` | `ignored_hosts`, `redacted_headers`, `db_stats`, `db_vacuum`, `bodies_purge` |
| _(always on)_ | `network_status`, `network_attach`, `network_detach`, `network_discover_dtd` |
