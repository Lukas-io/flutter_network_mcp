---
name: Bug report
about: Something doesn't work or behaves unexpectedly
labels: bug
---

> **Filing this is dead simple — agents are the recommended channel.**
> If you have Claude Code, Cursor, or another MCP-capable agent open right now, just say
> *"file a bug for this"* and it should open this template, fill the Quick report section,
> and submit. The Optional detail below is collapsible — skip it if you don't have it.

## Quick report (required — ~30 seconds)

**`flutter_network_mcp` version**
<!-- e.g. 0.8.6. The agent can read it from a network_status response, or run
     `dart pub global list | grep flutter_network_mcp`. Without it we can't tell
     whether your bug was already fixed in a later release. -->

**What broke**
<!-- One sentence. What did you (or the agent) expect, what actually happened? -->

**Failing tool call**
<!-- Tool name + the args you used. e.g.  network_search query:"timeout" -->

**`network_status` response**
<!-- Paste the structuredContent from a recent network_status call.
     If network_status itself is what's broken, write "n/a — network_status broken". -->

---

<details><summary><strong>Optional detail</strong> (helps a lot, never required)</summary>

### Environment
<!-- version is in the Quick report above -->
- Dart SDK: <!-- dart --version -->
- macOS / Linux / Windows version:
- IDE / agent: <!-- VS Code + Claude Code / Cursor / etc. -->

### Capture context
- DTD URI freshness: <!-- "fresh, app just started" or "DTD ~30 min old" -->
- Debug build? <!-- release/profile have the VM service stripped -->
- Server invocation: <!-- the `command` + `args` from your .mcp.json -->

### Reproduction steps
1.
2.
3.

### Stderr / MCP host logs
<!-- The MCP server writes stack traces to stderr (never into tool responses),
     so check the IDE's MCP server logs for a traceback. -->

</details>
