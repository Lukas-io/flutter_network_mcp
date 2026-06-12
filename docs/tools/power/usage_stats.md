---
tool: usage_stats
description: Aggregate view of how agents use this MCP — per-tool counts, outcome/latency, and the tool-to-next-tool transition graph, from the local usage capture.
when_to_use: When the maintainer (or you, reflecting) wants to see how the MCP's own tools are being used, to find friction or guide what to build next.
---

## DO NOT USE THIS TOOL WHEN

- You want data about the TARGET app's network traffic — that's `network_summarize` / `network_list`. This tool is about how the MCP's OWN tools are being called.
- Usage capture is opted out (`FLUTTER_NETWORK_MCP_NO_USAGE` / `FLUTTER_NETWORK_MCP_NO_TELEMETRY`) — it will just return empty.
- You need raw per-call rows — use the `flutter_network_mcp usage --show` CLI instead.

## Use this when

- Reflecting on a debugging session: which tools got used, what errored or returned empty, what followed what.
- The maintainer wants to see real usage to prioritise features or spot a confusing tool.

## Args

- `sinceMs` (int, optional) — relative window in ms (e.g. `3600000` = last hour). Omit or `0` for all history.
- `topTransitions` (int, optional) — how many tool→next-tool transitions to return, busiest first. Default 15, cap 100.

## Returns

```jsonc
{
  "summary": "47 call(s) across 9 turn(s) over all history, 12 distinct tool(s).",
  "totalEvents": 47,
  "totalTurns": 9,
  "tools": [
    { "tool": "network_list", "count": 14, "ok": 11, "error": 1, "empty": 2,
      "errorRate": 0.0714, "emptyRate": 0.1429, "p50Ms": 38, "p95Ms": 120,
      "avgResultBytes": 1840 }
  ],
  "transitions": [
    { "from": "network_status", "to": "alerts_drain", "count": 8 }
  ]
}
```

- `tools` is sorted by call count desc. `errorRate` / `emptyRate` are fractions.
- `transitions` are consecutive tool→next-tool pairs WITHIN a turn (a "turn" is a burst of calls grouped by the usage correlation id). They never bridge across the idle-gap boundary.

## Privacy

This reads only the local, privacy-safe `tool_events` capture: tool names, arg KEYS (never values), outcome categories, durations, sizes. No URLs, hosts, bodies, or log text are involved.

## Pairs well with

- `flutter_network_mcp usage --show` (CLI) — the raw events behind these aggregates.
