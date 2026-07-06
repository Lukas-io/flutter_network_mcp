# flutter_network_mcp

Give AI coding agents visibility into your running Flutter app's network traffic.

The [official Dart and Flutter MCP server](https://docs.flutter.dev/ai/mcp-server) is good at code and app introspection: it can fetch runtime errors, read the widget tree, hot reload, run tests, and search pub.dev. What it can't do is show an agent the network. There's no tool for HTTP requests, responses, sockets, or logged traffic. So when you're debugging an API bug with an agent, you're back to alt-tabbing to DevTools, copying the request, and pasting it into the chat by hand.

This server fills that gap. It connects to a running Flutter or Dart app through the Dart Tooling Daemon and exposes the app's network traffic, sockets, and logs as tools the agent calls directly. Captures persist to a local SQLite database so they survive across sessions, and the server flags HTTP errors, slow requests, and Flutter exceptions on its own so the agent can pick them up without being asked.

## Why

Agents debug better with real runtime data than with pasted snippets. Instead of you shuttling requests back and forth, the agent reads the live network tab itself, searches every body you've captured, compares today's behavior against a previous session, and opens an investigation when something breaks.

Good for:

- Debugging API issues with an agent without copy-pasting requests around.
- Comparing app behavior across sessions, for example whether the auth header changed since Tuesday.
- Generating a HAR file from a capture session to hand a coworker.
- Finding the one request containing a specific error across weeks of history.

Not for: production observability, traffic outside `dart:io` HTTP, or release and profile builds where the VM service is stripped.

## Requirements

- Dart SDK or Flutter installed, with `~/.pub-cache/bin` on your `$PATH`.
- A Flutter or Dart app running in debug mode, so the VM service is available.
- An MCP-capable agent host such as Claude Code or Cursor.

## Install

```bash
dart pub global activate -s git https://github.com/Lukas-io/flutter_network_mcp.git
flutter_network_mcp install
```

The `install` step compiles a native binary so the server starts in under 100ms instead of recompiling a JIT snapshot on every launch. Skipping it can cause the agent host to intermittently mark the server as failed on first connect.

## Configure

Add the server to your project's `.mcp.json`, or `~/.claude.json` for machine-wide:

```json
{
  "mcpServers": {
    "flutter-network": {
      "type": "stdio",
      "command": "flutter_network_mcp"
    }
  }
}
```

The server auto-discovers a running app's Tooling Daemon on startup, so no connection URI is needed in most setups. To target a specific daemon, pass `--dtd-uri "ws://127.0.0.1:<port>/<token>="`.

## Quickstart

Once configured, ask your agent to work with the running app:

```
You:    Attach to my app and tell me what's breaking.
Agent:  network_status -> network_attach -> alerts_drain
        3 alerts, 1 critical (Null check on null at home_screen:42),
        2 errors (503 on /v1/login)

You:    Find the login request that failed.
Agent:  network_search query:"invalid_token"
        POST /v1/login, 500, snippet "invalid_token"

You:    Show me the full response.
Agent:  network_get, returns headers and body
```

Captures are saved automatically. The next day, `session_list` shows what you captured and `session_open` reopens it.

## What it does

Live capture. HTTP requests (method, URL, headers, status, bodies), `dart:io` sockets, and app logs, streamed as they happen.

Persistence. Every attach opens a SQLite session. Reopen past sessions, run ad-hoc SQL, or export to HAR 1.2 for sharing.

Alerts. Detection rules run on every request and log line, flagging 4xx and 5xx responses, `dart:io` errors, slow requests, and Flutter exceptions. The agent drains the queue at the start of an investigation.

Full-text search. Ranked, highlighted search across every captured URL and body.

Multi-app. Attach to several running apps at once, for example a customer app and a driver app, and correlate requests across them by a shared id.

Capture control. Host and path glob filters, an opt-in allowlist, and an ephemeral no-persist mode for sessions you don't want written to disk. Sensitive fields are redacted before storage per a configurable policy.

The server exposes 40 tools across HTTP, sockets, logs, alerts, search, sessions, SQL, and admin categories. Every tool returns a consistent shape with a summary, suggested next steps, and any warnings, so the agent can act without parsing prose.

## Documentation

- [Tool reference](docs/tools): every tool has its own page, including when not to use it.
- [Configuration and environment variables](docs/configuration.md): capability gating, auto-attach, data directory, database size caps.
- [Telemetry and privacy](docs/telemetry.md): what is collected, what is never collected, the local audit log, and how to opt out.

## Contributing

Reports help. If you use an MCP-capable agent, say "file a bug for this" or "file a UX friction report" and the agent will fill and submit the template. Bug and friction templates live in [`.github/ISSUE_TEMPLATE`](.github/ISSUE_TEMPLATE).

## Local development

```bash
git clone https://github.com/Lukas-io/flutter_network_mcp.git
cd flutter_network_mcp
dart pub get
dart analyze
dart run bin/flutter_network_mcp.dart --dtd-uri 'ws://...' --data-dir /tmp/captures
```

Built with `package:dart_mcp`, `package:dtd`, `package:vm_service`, and `package:sqlite3`.

## License

MIT
