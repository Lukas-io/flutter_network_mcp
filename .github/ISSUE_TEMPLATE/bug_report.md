---
name: Bug report
about: Something doesn't work or behaves unexpectedly
labels: bug
---

## What happened

<!-- One paragraph. What did you expect? What did you actually see? -->

## How to reproduce

1.
2.
3.

## Environment

- `flutter_network_mcp` version: <!-- run: dart pub global list | grep flutter_network_mcp -->
- Dart SDK: <!-- run: dart --version -->
- macOS / Linux / Windows version:
- IDE / agent: <!-- VS Code + Claude Code / Cursor / etc. -->

## Capture context (if applicable)

- DTD URI age at time of bug: <!-- e.g. "fresh, app just started" or "DTD ~30 min old" -->
- Was the app a debug build? <!-- release/profile have the VM service stripped -->
- Server invocation: <!-- the `command` + `args` from your .mcp.json -->
- `network_status` response: <!-- if you can, paste the structuredContent -->

## Anything else

<!-- Logs from stderr if relevant. The MCP server writes stack traces to stderr
     (never into responses), so check the IDE's MCP server logs for a traceback. -->
