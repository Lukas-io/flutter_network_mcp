# flutter_network_mcp

You're debugging a flaky API call in your Flutter app. You alt-tab to DevTools, find the request, copy the response, paste it into the chat with Claude. Twenty seconds. Then it happens again ten minutes later. And again. By the end of the session you've spent more time being the agent's hands than thinking about the bug.

This MCP server skips the alt-tab. It plugs into any running Flutter or Dart app via the Tooling Daemon, exposes the DevTools "Network" tab — plus dart:io sockets and app logs — as tools your agent calls directly, and persists everything to a local SQLite database so when you come back tomorrow asking "what was that 500 from yesterday?", it knows.

## What this is for

- Debugging API issues with Claude without copy-pasting requests around.
- Asking the agent to compare today's app behavior against a previous session — "did the auth header change since Tuesday?"
- Generating a HAR file from a capture session you can hand a coworker without screen-sharing.
- Ad-hoc analysis: `SELECT host, COUNT(*) FROM http_requests WHERE session_id=… GROUP BY host ORDER BY 2 DESC`.

Not for: production observability, traffic outside `dart:io` HTTP, or release/profile builds where the VM service is stripped.

## Install

```bash
dart pub global activate -s git https://github.com/Lukas-io/flutter_network_mcp.git
```

That's the whole thing. The binary lands at `~/.pub-cache/bin/flutter_network_mcp` — which Flutter already adds to your `$PATH` — and ships its own SQLite native lib so there's no system dependency to chase. Same one-liner works on any Mac dev box.

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

`--dtd-uri` is optional — pass it once and `network_attach` works with no args. Otherwise the agent supplies the URI explicitly. The DTD WS URI is printed in the IDE console when you `flutter run`.

## What it does

### Live (while attached)

- **HTTP**: requests as they happen — method, URL, headers, status, both bodies. Filterable by host, method, status range. Cursor-based polling so the agent doesn't refetch what it's already seen.
- **Sockets**: `dart:io` TCP/UDP byte counts and lifetimes.
- **Logs**: `Logging` (package:logging), `Stdout`, `Stderr` streams flow into an in-memory ring buffer (500 entries).
- Bodies truncate at 4 KB by default. When truncated, the response includes `totalSize` and `truncated:true` so the agent knows to call `network_body` for a byte range.

### Persistent (across sessions)

Every `network_attach` opens a SQLite session. A background writer polls every 2 seconds and persists:

- HTTP requests + headers + bodies (BLOBs)
- Socket stats
- Log/stdout/stderr records — forwarded straight from the stream

When you reattach tomorrow, run `session_list` to see what's there, `session_open <id>` to point every read tool at that session instead of the live VM service. `session_close` flips back to live. `session_export <id> har` writes HAR 1.2 (opens in Chrome DevTools or Insomnia) or NDJSON for grep/jq. `network_query` runs read-only SQL.

### Why this matters for LLM context

Every list-style tool filters at the source, enforces hard caps (50 default / 200 max for HTTP; 100 / 500 for logs; 256 KB max per body chunk), and returns a `nextCursor`. The point is your agent doesn't drown trying to read a 200 KB JSON response when it only needed the status code, and doesn't keep refetching things it already saw.

## The 17 tools

| Category | Tools |
|---|---|
| **Lifecycle** | `network_status` · `network_attach` · `network_detach` |
| **HTTP** | `network_list` · `network_get` · `network_body` · `network_clear` |
| **Sockets** | `socket_list` · `socket_get` · `socket_clear` |
| **Logs** | `logs_tail` · `logs_clear` |
| **Sessions** | `session_list` · `session_open` · `session_close` · `session_export` |
| **SQL** | `network_query` |

Each tool has a JSON schema with field descriptions — `tools/list` over the MCP wire is the full reference.

## The database

Lives at `${XDG_DATA_HOME:-~/.local/share}/flutter_network_mcp/captures.db`. Override with `--data-dir`.

```
sessions(id, started_at, ended_at, app_name, vm_service_uri, isolate_id, project_path, note)
http_requests(session_id, vm_id, method, url, host, path, status_code, reason_phrase,
              start_us, end_us, duration_us, request_size, response_size, content_type,
              request_headers_json, response_headers_json, has_error, bodies_fetched)
http_bodies(session_id, vm_id, which, bytes BLOB, size)
socket_events(session_id, vm_id, socket_type, address, port, start_us, end_us,
              last_read_us, last_write_us, read_bytes, write_bytes)
log_records(id, session_id, timestamp_ms, source, level, logger, message, error, stack_trace)
```

Indexes on `(session_id, start_us)`, `host`, `status_code`, `(session_id, timestamp_ms)`, `level`. WAL mode. Foreign keys with cascade delete. `network_query` is `SELECT`-only with a 500-row cap.

## A typical session

```
You:    network_attach
Agent:  liveSessionId: 14

# poke around the app
You:    network_list since:0 limit:5
Agent:  [5 requests, newest first]

You:    network_get id=abc123
Agent:  full headers + first 4 KB of body, truncated:true totalSize:18432

You:    network_body id=abc123 which=response offset=4096 length=16384
Agent:  bytes 4096-18432

You:    logs_tail levelMin=800
Agent:  [recent warnings/errors]

You:    network_detach

# tomorrow
You:    session_list
Agent:  session 14 — 38 requests, 12 logs, ended yesterday

You:    session_open id=14
You:    network_query "SELECT host, AVG(duration_us)/1000 ms FROM http_requests WHERE session_id=14 GROUP BY host"
You:    session_export id=14 format=har outPath=/tmp/yesterday.har
```

## Known issues

- **Zombie DTD.** A DTD instance can outlive useful service — connects fine, never responds to RPCs. If `network_attach` hangs longer than ~10 seconds, restart the Flutter app to spawn a fresh DTD.
- **Body backfill lag.** Bodies are fetched on the writer's next 2s tick after a request completes. Live mode shows them immediately; history mode may be a beat behind.
- **Single-instance writer.** WAL mode means multiple MCP server instances against one DB *should* work, but it's untested. One MCP server per machine is the assumption.

## Local development

```bash
git clone <repo>
cd flutter_network_mcp
dart pub get
dart analyze
dart run tool/probe.dart 'ws://127.0.0.1:<port>/<token>='     # smoke-test DTD connectivity
dart run bin/main.dart --dtd-uri 'ws://...' --data-dir /tmp/captures
```

Built with `package:dart_mcp`, `package:dtd`, `package:vm_service`, and `package:sqlite3`.
