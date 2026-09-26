---
tool: usage_stats
description: Aggregate view of how agents use this MCP — per-tool counts, outcome/latency, and the tool-to-next-tool transition graph, from the local usage capture.
when_to_use: When the maintainer (or you, reflecting) wants to see how the MCP's own tools are being used, to find friction or guide what to build next.
---

## DO NOT USE THIS TOOL WHEN

- You want data about the TARGET app's network traffic — that's `network_summarize` / `network_list`. This tool is about how the MCP's OWN tools are being called.
- Usage capture is opted out (`GLINT_NETWORK_NO_USAGE` or `GLINT_NETWORK_NO_TELEMETRY` set to `true`, `1`, `yes` or `on`). New calls are not recorded, so the tool only reports events stored before the opt-out (or nothing).
- You need raw per-call rows — use the `glint_network usage --show` CLI instead.

## Use this when

- Reflecting on a debugging session: which tools got used, what errored or returned empty, what followed what.
- The maintainer wants to see real usage to prioritise features or spot a confusing tool.

## How it works

Every registered tool call (this one included) is recorded in the local `tool_events` table of the capture DB: tool name, sorted arg keys, outcome, duration, result size, an estimated token count (result characters / 4), the `errorKind` of an error reply, and whether the reply was `degraded`. Outcome is `error` when the handler threw or returned an error, `empty` when the reply has a top-level `count: 0`, else `ok`. Calls are grouped into turns by a correlation id that rolls over after 60 s without a call (`GLINT_NETWORK_USAGE_GAP_MS`, minimum 1000) and differs per server process.

`usage_stats` reads up to 50 000 of those events (all history, or those newer than `sinceMs`), ordered by correlation id then insertion order, and aggregates them per tool and per consecutive pair of calls within a turn. It is registered regardless of `--capabilities` and reads across all sessions and processes that share the DB.

## Args

- `sinceMs` (int, optional). Relative window in ms (e.g. `3600000` = last hour). Omit, `0` or negative for all history.
- `topTransitions` (int, optional). How many tool to next-tool transitions to return, busiest first. Default 15, cap 100; values <= 0 fall back to 15.

## Returns

```jsonc
{
  "summary": "47 call(s) across 9 turn(s) over all history, 12 distinct tool(s).",
  "window": "all history",
  "totalEvents": 47,
  "totalTurns": 9,
  "totalEstimatedTokens": 21480,
  "tools": [
    { "tool": "network_list", "count": 14, "ok": 11, "error": 1, "empty": 2,
      "errorRate": 0.0714, "emptyRate": 0.1429, "p50Ms": 38, "p95Ms": 120,
      "avgResultBytes": 1840, "avgEstimatedTokens": 460,
      "totalEstimatedTokens": 6440, "degraded": 1,
      "errorKinds": { "unresponsive_vm": 1 } }
  ],
  "transitions": [
    { "from": "network_status", "fromOutcome": "ok", "to": "alerts_drain", "count": 8 }
  ],
  "selfCorrection": [
    { "tool": "network_list", "signal": "empty", "occurrences": 2,
      "recovered": 1, "recoveryRate": 0.5 }
  ],
  "nextSteps": [
    "network_list has the highest error rate (7% of 14 call(s)) ...",
    "usage_stats sinceMs:3600000 ...",
    "glint_network usage --show ..."
  ]
}
```

- `window` is `all history` or the window as `<n>ms`, `<n>m`, `<n>h` or `<n>d` (rounded).
- `tools` is sorted by call count desc. `errorRate` / `emptyRate` are fractions (4 decimals). `p50Ms` / `p95Ms` are `null` when no durations were recorded. `avgResultBytes`, `avgEstimatedTokens`, `totalEstimatedTokens`, `degraded` and `errorKinds` appear only when non-empty; `errorKinds` counts error replies by `errorKind`, busiest first (errors without a kind are not listed).
- `transitions` are consecutive tool to next-tool pairs WITHIN a turn (a "turn" is a burst of calls grouped by the usage correlation id), keyed by the outcome of the first call (`fromOutcome`: `ok`, `error` or `empty`). They never bridge across the idle-gap boundary.
- `selfCorrection` (only when present): for each tool and signal (the `errorKind` of an error, `error` when it had none, or `empty`), how often another call followed in the same turn and how often that next call came back `ok`.
- `nextSteps` is empty when no events were found. Otherwise it names the tool with the highest error rate (when above zero), then suggests narrowing to the last hour and the raw CLI view.

A DB read failure returns `usage_stats query failed: ...` (no `errorKind`) with a `nextSteps` pointing at the `glint_network usage` CLI.

## Privacy

This reads only the local, privacy-safe `tool_events` capture: tool names, arg KEYS (never values), outcome categories, error kinds, degraded flags, durations, sizes and token estimates. No URLs, hosts, bodies, or log text are involved.

## Pairs well with

- `glint_network usage --show` (CLI) — the raw events behind these aggregates.

## Example

```
> usage_stats sinceMs:3600000 topTransitions:5
< {summary:"12 call(s) across 2 turn(s) over 1h, 6 distinct tool(s).",
   tools:[{tool:"network_list", count:4, error:1, errorKinds:{unresponsive_vm:1}, ...}],
   transitions:[{from:"network_list", fromOutcome:"error", to:"network_attach", count:1}, ...]}
```
