# flutter_network_mcp

You're debugging a flaky API call in your Flutter app. You alt-tab to DevTools, find the request, copy the response, paste it into the chat with Claude. Twenty seconds. Then it happens again ten minutes later. And again. By the end of the session you've spent more time being the agent's hands than thinking about the bug.

This MCP server skips the alt-tab. It plugs into any running Flutter or Dart app via the Tooling Daemon, exposes the DevTools "Network" tab — plus dart:io sockets and app logs — as tools your agent calls directly, persists everything to a local SQLite database so it survives across sessions, and **proactively surfaces issues** (HTTP errors, slow requests, Flutter exceptions) without you having to ask. There's also full-text search across every body you've ever captured.

## What this is for

- Debugging API issues with Claude without copy-pasting requests around.
- Asking the agent to compare today's app behavior against a previous session — "did the auth header change since Tuesday?"
- Generating a HAR file from a capture session you can hand a coworker without screen-sharing.
- Finding the one request that contained a specific error message across weeks of history.
- Letting the agent open an investigation with `alerts_drain` — it tells you what's broken without being asked.

Not for: production observability, traffic outside `dart:io` HTTP, or release/profile builds where the VM service is stripped.

## Install

```bash
dart pub global activate -s git https://github.com/Lukas-io/flutter_network_mcp.git
```

The binary lands at `~/.pub-cache/bin/flutter_network_mcp` (Flutter installs put that directory on `$PATH`). `package:sqlite3` ships its own native lib so there's no system dependency to chase.

Then in any project's `.mcp.json` (or `~/.claude.json` for machine-wide):

```json
{
  "mcpServers": {
    "flutter-network": {
      "type": "stdio",
      "command": "flutter_network_mcp",
      "args": ["--dtd-uri", "ws://127.0.0.1:<port>/<token>="]
    }
  }
}
```

`--dtd-uri` is optional — pass it once and `network_attach` works with no args. The DTD WS URI is printed in the IDE console when you `flutter run`.

## Environment knobs (fine-tune at startup)

Beyond capability gating, these env vars tune runtime behavior:

| Env var | Default | Clamped to | What it does |
|---|---|---|---|
| `FLUTTER_NETWORK_MCP_POLL_MS` | 2000 | 50–60000 | CaptureWriter poll interval. Lower for chatty apps, higher for quiet ones. |
| `FLUTTER_NETWORK_MCP_LOG_BUFFER` | 500 | 50–10000 | In-memory log ring buffer size for `logs_tail` live mode. |
| `FLUTTER_NETWORK_MCP_DTD_URI` | — | — | Default DTD URI for `network_attach`. |
| `FLUTTER_NETWORK_MCP_DATA_DIR` | — | — | Directory for `captures.db`. Equivalent to `--data-dir`. When set, the candidate-fallback chain is skipped — unwritable values error loudly. |
| `FLUTTER_NETWORK_MCP_CAPABILITIES` | (all) | — | Allowlist (see below). |
| `FLUTTER_NETWORK_MCP_DISABLE` | — | — | Denylist (see below). |

## Capability gating (control your context budget)

Thirty-two tools is a lot of schema for the agent to load. Disable the categories you don't use:

```json
{
  "mcpServers": {
    "flutter-network": {
      "type": "stdio",
      "command": "flutter_network_mcp",
      "args": [
        "--dtd-uri", "ws://...",
        "--capabilities", "http,alerts,sessions,search"
      ]
    }
  }
}
```

The opposite is `--disable sockets,sql,admin` — start from "all on" and remove. Lifecycle (`network_status`, `network_attach`, `network_detach`) is always on.

Categories: `http` · `sockets` · `logs` · `alerts` · `search` · `sessions` · `sql` · `admin`. Env vars: `FLUTTER_NETWORK_MCP_CAPABILITIES`, `FLUTTER_NETWORK_MCP_DISABLE`.

When a category is disabled, the disabled tools don't appear in `tools/list` AND the corresponding capture paths don't run (no log subscription if `logs` is off; no alert detection if `alerts` is off). Real context AND CPU savings.

## What it does

### Live (while attached)

- **HTTP**: requests as they happen — method, URL, headers, status, both bodies. Filterable, cursor-based, body-truncated by default.
- **Sockets**: `dart:io` TCP/UDP byte counts.
- **Logs**: `Logging` + `Stdout` + `Stderr` streams.
- **Bodies truncate at 4 KB** by default. Truncated payloads return `totalSize` + `truncated:true` so the agent knows to call `network_body` for a byte range.

### Persistent (across sessions)

Every `network_attach` opens a SQLite capture session. A 2-second writer persists HTTP requests + headers + bodies + sockets + log records. When you reattach tomorrow:

- `session_list` shows what's there
- `session_open id:<n>` points every read tool at that session
- `session_export id:<n> format:har` writes a HAR 1.2 file (Chrome DevTools / Insomnia compatible)
- `network_query "SELECT ..."` for ad-hoc SQL

### Proactive (alerts pipeline)

The server runs detection rules on every captured request and log line:

| Rule | Fires on | Severity |
|---|---|---|
| `http_5xx` | HTTP status 500–599 | error |
| `http_4xx` | HTTP status 400–499 | warning |
| `http_error` | `dart:io` request/response errors | error |
| `http_slow` | duration > 3000ms (configurable) | warning |
| `log_keyword` | log matches `/error\|exception\|failed\|denied\|timeout\|refused\|crash/i` | warning (severe at level ≥1200) |
| `flutter_error` | log matches Flutter exception patterns (FlutterError, RenderFlex overflow, null check on null, setState after dispose, etc.) | critical |

The agent calls `alerts_drain` at the top of an investigation and gets the queue. `alerts_peek` reads without clearing. `alerts_config` tunes thresholds and toggles rules at runtime.

### Search (FTS5)

`network_search query="invalid_token"` returns ranked matches across URLs + utf8 request/response bodies with «highlighted» snippets. Queries are phrase-quoted by default so hyphens and special chars work naturally.

### Productivity polish

- **`network_diff idA idB`** — structural diff: status/method/url, response headers added/removed/changed, body hunks (line-based, for utf8 bodies).
- **`network_replay id`** — emits a runnable curl command. Authorization/Cookie/X-API-Key headers redacted by default; pass `redact:false` for local use.
- **`session_note id note`** — annotate sessions so future-you can find them ("auth bug 2026-05-21").
- **`ignored_hosts action:add host:...`** — drop analytics/Sentry/telemetry traffic at capture time so the DB only contains the requests that matter.

## The 32 tools

| Category | Tools |
|---|---|
| **Lifecycle** | `network_status` · `network_attach` · `network_detach` |
| **HTTP** | `network_list` · `network_get` · `network_body` · `network_clear` · `network_diff` · `network_replay` |
| **Sockets** | `socket_list` · `socket_get` · `socket_clear` |
| **Logs** | `logs_tail` · `logs_clear` |
| **Alerts** | `alerts_drain` · `alerts_peek` · `alerts_config` · `alerts_clear` · `alert_patterns` |
| **Search** | `network_search` |
| **Sessions** | `session_list` · `session_open` · `session_close` · `session_export` · `session_note` · `session_delete` |
| **SQL** | `network_query` |
| **Admin** | `ignored_hosts` · `redacted_headers` · `db_stats` · `db_vacuum` · `bodies_purge` |

**Per-tool docs live in [`docs/tools/`](docs/tools/) — every tool has its own page with a `## DO NOT USE THIS TOOL WHEN` section at the top.** Point your agent at these. The negative cases catch the bulk of misuse before it happens.

### The agent-facing contract

Every tool response — success OR error — follows the same shape, so an agent can branch on it without parsing prose:

- **`summary`** — one human-readable sentence (echo-able to the user).
- **`nextSteps`** — 1–3 concrete commands the agent can execute next; filtered against active capabilities.
- **`warnings`** — only present when something is partially degraded (truncation, in-flight, host not yet backfilled, etc.).
- **`pendingAlerts`** — `{count, critical?}` auto-injected on any success response when alerts are queued in scope. Lets the agent notice fresh alerts during normal work without polling `network_status` (the alerts pipeline is push-like in practice).
- **Errors** are `{error, contextual fields, nextSteps}` — never bare strings, never stack traces.
- Destructive ops (`session_delete`, `bodies_purge`, `alerts_clear` with `drainedOnly:false`) require explicit `confirm:true` / `force:true`; the default is a dry-run that reports impact.

## A typical session

```
You:    network_status
Agent:  capabilities:[http,alerts,sessions,search], attached:false, alerts:{pending:0}

You:    network_attach
Agent:  liveSessionId: 14

# poke around the app, server captures + alerts in the background

You:    alerts_drain
Agent:  3 alerts — 1 critical (Null check on null at home_screen:42), 2 errors (503 on /v1/login)

You:    network_search query:"invalid_token"
Agent:  req-1 — POST /v1/login — 500 — snippet "«invalid_token»"

You:    network_get id:req-1
Agent:  headers + 4 KB of body, truncated:true totalSize:18432

You:    network_body id:req-1 which:response offset:4096 length:16384
Agent:  bytes 4096-18432

You:    network_detach
You:    session_note id:14 note:"auth-bug repro for #1842"

# tomorrow
You:    session_list
Agent:  session 14 — auth-bug repro for #1842 — 38 req, 12 logs, 3 alerts

You:    session_open id:14
You:    network_query "SELECT host, AVG(duration_us)/1000 ms FROM http_requests WHERE session_id=14 GROUP BY host"
You:    session_export id:14 format:har outPath:/tmp/auth-bug.har
```

## The database

Lives at one `captures.db` file resolved via a fallback chain:

| Platform | Default path |
|---|---|
| macOS | `~/Library/Application Support/flutter_network_mcp/captures.db` |
| Linux / other | `${XDG_DATA_HOME:-~/.local/share}/flutter_network_mcp/captures.db` |

Override with `--data-dir` or `FLUTTER_NETWORK_MCP_DATA_DIR`. When neither is set, the server walks a candidate list (`$XDG_DATA_HOME` → platform default → `~/.cache`) and uses the first writable one, emitting a one-line stderr note if it fell back. Schema lives in [`docs/tools/network_query.md`](docs/tools/network_query.md).

> **macOS users upgrading from ≤0.5.15**: on first launch of 0.5.16, the server moves `~/.local/share/flutter_network_mcp/` to `~/Library/Application Support/flutter_network_mcp/` (atomic rename, WAL files included). Skipped if either dir's `captures.db` is missing or the new dir already has one. To opt out: set `--data-dir` or `FLUTTER_NETWORK_MCP_DATA_DIR` before launching.

WAL mode. Foreign keys with cascade delete. FTS5 virtual table for `network_search`. Indexes on `(session_id, start_us)`, `host`, `status_code`, `(session_id, timestamp_ms)`, `level`, `(drained, severity, ts_ms)`.

**Segmentation**: every captured row (`http_requests`, `http_bodies`, `socket_events`, `log_records`, `alerts`) has a `session_id` FK with `ON DELETE CASCADE`. One row in `sessions` per `network_attach` call — with `app_name`, `vm_service_uri`, `isolate_id`, `project_path`, `note`. Read tools always scope to the current live or opened session; cross-session queries go through `network_query`.

## Known issues

- **Zombie DTD** — A DTD can outlive useful service: WS upgrades succeed but RPCs hang forever. `network_attach` now fails fast within 5 seconds when this happens with a clear error. Restart the Flutter app to spawn a fresh DTD.
- **Body backfill lag** — Bodies are fetched on the writer's 2-second tick after a request completes. Live mode shows them immediately; history mode may be a beat behind. Also affects `network_search`, since FTS indexing happens during backfill.
- **Single-instance writer** — WAL mode means multiple MCP server instances against one DB *should* work, but it's untested. One MCP server per machine is the assumption.

## Local development

```bash
git clone <repo>
cd flutter_network_mcp
dart pub get
dart analyze
dart run tool/probe.dart 'ws://127.0.0.1:<port>/<token>='     # smoke-test DTD connectivity
dart run tool/seed.dart /tmp/test-captures                    # seed synthetic data
dart run bin/flutter_network_mcp.dart --dtd-uri 'ws://...' --data-dir /tmp/captures
```

Built with `package:dart_mcp`, `package:dtd`, `package:vm_service`, and `package:sqlite3`.
