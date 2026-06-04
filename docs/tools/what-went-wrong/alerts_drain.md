---
tool: alerts_drain
description: Return AND clear pending alerts (newest-first), with severity breakdown, summary, and capability-aware nextSteps.
when_to_use: At the start of any debugging turn — it surfaces issues the server already detected so you don't have to ask.
---

## DO NOT USE THIS TOOL WHEN

- You haven't attached and no session is opened — `effectiveSessionId` is null, the queue is global; pass `sessionId` explicitly or open one first.
- You want to look without committing — use `alerts_peek`. Drain marks alerts as seen; a second call returns empty.
- The user wants you to keep ignoring noisy alerts — tune them via `alerts_config` (disable rules / raise `slowThresholdMs`), not by silently draining.
- You're polling more than ~once per turn — alerts only fire on capture-writer ticks (every 2s); over-polling doesn't surface anything new.

## Use this when

- Starting a debugging conversation — call this first if `network_status.alerts.pendingTotal > 0`.
- After triggering a user action — drain to see what fired.
- Periodically during a long investigation to catch new issues.

## How it works

Selects undrained rows from `alerts` filtered by `severityMin` (info < warning < error < critical), marks them drained, returns. The summary line reports per-severity counts ("Drained 5 alert(s): 1 critical, 2 error, 2 warning"). `nextSteps` points at `network_get` for the first HTTP-source alert and `logs_tail` for the first log-source alert (capability-gated).

**Deduplication by signature (0.6.3+).** Repeat events that reflect the same underlying issue collapse into a single row with `occurrenceCount` incremented. A `RenderFlex` overflow that fires 200 times because the offending widget is repeated 200 times in a list shows up as ONE row with `occurrenceCount: 200`, not 200 rows. Severity is bumped to the highest seen across the burst (a single critical inside 199 warnings escalates the row to critical). The `firstSeenMs` / `lastSeenMs` / `sourceId` / `lastSourceId` fields bracket the burst — pass `lastSourceId` to `network_get` to drill into the most recent event, `sourceId` for the first. Drained alerts don't merge with subsequent events; once acknowledged, a fresh occurrence starts a new row at count 1.

**Cross-session pattern memory (0.7.2+).** Each alert row that has a signature now carries a `priorOccurrences: [...]` array listing past sessions where the same signature fired. Each entry has `sessionId`, `startedAtMs`, `appName`, and the session's `note` (if the user wrote one). Per-project bug recurrence becomes the agent's memory: "you hit this RenderFlex overflow 3 days ago and your note says it was a missing Expanded." Default limit 3 past sessions, newest-first. Absent when no prior occurrences exist OR when the alert has no signature (legacy row).

## Args

- `sessionId` (int, optional) — defaults to current (live or viewed) session.
- `severityMin` (string, optional) — `"info"` | `"warning"` | `"error"` | `"critical"`.
- `limit` (int, default 50, hard cap 200).

## Returns

```json
{
  "sessionId": 14,
  "summary": "Drained 5 alert(s) session 14: 1 critical, 2 error, 2 warning.",
  "count": 5,
  "breakdown": {"critical":1, "error":2, "warning":2},
  "nextSteps": [
    "network_get id:\"req-3\" — full detail on the first HTTP-sourced alert",
    "logs_tail — context around the first log-sourced alert",
    "alerts_config — tune thresholds if these are noisy"
  ],
  "alerts": [
    {
      "id": 42,
      "sessionId": 14,
      "severity": "critical",
      "kind": "flutter_error",
      "title": "RenderFlex overflowed by 14 pixels on the right",
      "detail": "...",
      "sourceKind": "log",
      "sourceId": "log:101",
      "tsMs": 1780462000000,
      "occurrenceCount": 200,
      "priorOccurrences": [
        {
          "sessionId": 14,
          "startedAtMs": 1780462000000,
          "appName": "sanga_mobile",
          "note": "fixed by adding Expanded — lib/view/widgets/cart.dart"
        }
      ],
      "firstSeenMs": 1780462000000,
      "lastSeenMs": 1780462678000,
      "lastSourceId": "log:341",
      "signature": "a3f7c8d219b4"
    }
  ]
}
```

Per-alert `detail`/`sourceKind`/`sourceId` are omitted when null. Alert `kind` values: `http_5xx`, `http_4xx`, `http_error`, `http_slow`, `log_keyword`, `flutter_error`, plus any user-defined kinds via `alert_patterns`. The dedup fields (0.6.3+) — `occurrenceCount`, `firstSeenMs`, `lastSeenMs`, `lastSourceId`, `signature` — are always present on new rows; legacy rows (pre-v5 migration) default `occurrenceCount` to 1 and omit `lastSourceId` / `signature`.

## Pairs well with

- `alerts_peek` — non-mutating sibling.
- `network_get` / `logs_tail` — drill into the source via `sourceKind` + `sourceId`.
- `alerts_config` — turn off noisy rules instead of draining without acting.
- `alerts_clear` — bulk delete already-drained rows.

## Example

```
> network_status
< {alerts:{pending:5, critical:1}}
> alerts_drain severityMin:"warning"
< {summary:"Drained 5 alert(s) session 14: 1 critical, 2 error, 2 warning.", ...}
> network_get id:"req-3"
```
