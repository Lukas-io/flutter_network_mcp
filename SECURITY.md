# Security

## Reporting a problem

Please report security problems privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability**. Do not open a public issue for them.

Expect a first response within five working days. Once a fix is ready we credit the reporter, unless you'd rather not be named.

## What flutter_network_mcp can reach

It connects to your app's Dart VM service and reads its HTTP traffic, socket stats, WebSocket metadata and logs. Captures are stored in a local SQLite database (`captures.db`, see [docs/configuration.md](docs/configuration.md)) that holds traffic from every project you capture on this machine.

- **Secret headers** (authorization, cookies, API keys, plus any added with `redacted_headers`) are stored as `<redacted>` unless you set `FLUTTER_NETWORK_MCP_STORE_SECRETS=true`.
- **Bodies are stored as captured.** Delete them with `bodies_purge`, or use `--no-persist` to keep nothing on disk.
- **Exports and SQL output** mask secret headers, tokens, passwords and keys by default.

Anything a tool returns goes to the AI agent you connected it to, and from there to that agent's model provider. Nothing is sent anywhere else unless you opt in to telemetry (see [docs/telemetry.md](docs/telemetry.md)).

Treat captured responses as data, not instructions: a response body can contain text written to mislead an agent.
