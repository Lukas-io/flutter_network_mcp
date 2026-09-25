---
tool: alerts_drain
description: Return AND clear pending alerts (newest-first), with severity breakdown, summary, and capability-aware nextSteps.
when_to_use: At the start of any debugging turn — it surfaces issues the server already detected so you don't have to ask.
---

## DO NOT USE THIS TOOL WHEN

- Nothing is attached and no session is opened: the call fails with a scope error (not a global drain). Pass `sessionId`, `session_open` one, or `network_attach` first.
- You want to look without committing — use `alerts_peek`. Drain marks alerts as seen; a second call returns empty.
- The user wants you to keep ignoring noisy alerts — tune them via `alerts_config` (disable rules / raise `slowThresholdMs`), not by silently draining.
- You're polling more than ~once per turn: HTTP alerts fire on capture-writer ticks (default every 2s, `FLUTTER_NETWORK_MCP_POLL_MS`) and log alerts as each record is stored, so over-polling doesn't surface anything new.

## Use this when

- Starting a debugging conversation — call this first if `network_status.alerts.pendingTotal > 0`.
- After triggering a user action — drain to see what fired.
- Periodically during a long investigation to catch new issues.

## How it works

Resolves one session (explicit `sessionId`, then `appNameContains`, then the `session_open` view, then the sole attached session; with 2+ attached it picks the one attached from this project, else the most recently used, and reports `scope.pickedBy` plus `scope.others`). Selects that session's undrained rows from `alerts` filtered by `severityMin` (info < warning < error < critical), newest first by first-seen time, marks them drained, returns. The summary line reports per-severity counts ("Drained 5 alert(s) session 14: 1 critical, 2 error, 2 warning."). `nextSteps` points at `network_get` for the first HTTP-source alert and `logs_tail` for the first log-source alert (capability-gated), then `alerts_config`. With nothing pending, nextSteps says whether new alerts can still arrive (a session whose capture is complete gets none).

`network_status.alerts.pendingTotal` counts pending alerts across ALL sessions, so a drain scoped to one session can return fewer.

**Deduplication by signature (0.6.3+).** Repeat events that reflect the same underlying issue (same `kind` and same title after digits, hex ids and home paths are normalized) collapse into a single row with `occurrenceCount` incremented. A `RenderFlex` overflow that fires 200 times because the offending widget is repeated 200 times in a list shows up as ONE row with `occurrenceCount: 200`, not 200 rows. Severity is bumped to the highest seen across the burst (a single critical inside 199 warnings escalates the row to critical). The `firstSeenMs` / `lastSeenMs` / `sourceId` / `lastSourceId` fields bracket the burst. For HTTP alerts (`sourceKind:"http"`) the ids are request ids: pass `lastSourceId` to `network_get` for the most recent event, `sourceId` for the first. Log alerts carry `log:<rowId>` (custom patterns: `log:<rowId>:<patternId>`), which no tool takes as an id; find the record with `logs_tail messageContains:` or `correlate_at tsMs:<firstSeenMs>`. Drained alerts don't merge with subsequent events; once acknowledged, a fresh occurrence starts a new row at count 1.

**Severity rules.** `flutter_error` is `critical` only for the first one in a session; later new `flutter_error` rows start at `error`. `http_5xx` is `error`, or `critical` when the same host already had 2+ 5xx occurrences in the last 60s. `http_4xx` and `http_slow` are `warning`, `http_error` is `error`, `log_keyword` is `error` for records at level >= 1200 (SEVERE) and `warning` otherwise. `detail` is the log message (cut at 4096 chars for `flutter_error`, 2048 for `log_keyword` and custom patterns), the dart:io error for `http_error`, or the reason phrase for `http_5xx` / `http_4xx`.

**Housekeeping.** An hourly sweep keeps at most 200 pending alerts per session (oldest dropped) and deletes alerts older than `alerts_config` `retentionDays` (default 14) except those of attached sessions.

**Cross-session pattern memory (0.7.2+).** Each alert row that has a signature now carries a `priorOccurrences: [...]` array listing past sessions where the same signature fired. Each entry has `sessionId`, `startedAtMs`, `appName`, and the session's `note` (if the user wrote one). Per-project bug recurrence becomes the agent's memory: "you hit this RenderFlex overflow 3 days ago and your note says it was a missing Expanded." Default limit 3 past sessions, newest-first. Absent when no prior occurrences exist OR when the alert has no signature (legacy row).

## Args

- `sessionId` (int, optional): session to read. Omit to auto-resolve (see How it works). Not validated: an unknown id just returns nothing.
- `appNameContains` (string, optional): pick an attached session by app-name substring instead. Must match exactly one attached session.
- `severityMin` (string, optional): `"info"` | `"warning"` | `"error"` | `"critical"`, case-insensitive. Default: any.
- `limit` (int, default 50, hard cap 200). Values <= 0 fall back to 50.

## Returns

```json
{
  "scope": {"sessionId": 14, "appName": "sanga_mobile", "isLive": true},
  "sessionId": 14,
  "summary": "Drained 5 alert(s) session 14 (sanga_mobile): 1 critical, 2 error, 2 warning.",
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
          "sessionId": 9,
          "startedAtMs": 1780200000000,
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

Per-alert `detail`/`sourceKind`/`sourceId` are omitted when null; `breakdown` is omitted when nothing was returned. `priorOccurrences` only lists OTHER sessions (up to 3, newest first). Alert `kind` values: `http_5xx`, `http_4xx`, `http_error`, `http_slow`, `log_keyword`, `flutter_error`, `http_anomaly` (0.7.3+, baseline-relative latency regression), `http_anomaly_errors` (0.7.3+, baseline-relative error-rate spike), plus any user-defined kinds via `alert_patterns`. The `http_anomaly` rule toggle in `alerts_config` covers both anomaly kinds. The dedup fields (0.6.3+: `occurrenceCount`, `firstSeenMs`, `lastSeenMs`, `lastSourceId`, `signature`) are always present on new rows; legacy rows (pre-v5 migration) default `occurrenceCount` to 1 and omit `lastSourceId` / `signature`.

Errors:
- Scope errors come back with `error`, `nextSteps` (plus `attached` / `matches` lists) and an `errorKind`: `no_session` when nothing is attached or opened, or no attached session matches `appNameContains`; `bad_argument` when several match.
- An unknown `severityMin` value fails as `errorKind: "bad_argument"` with `Unknown severityMin "<value>". Expected one of: info, warning, error, critical.`, before anything is drained. Fix the value and retry. A DB failure is `internal`.

## Pairs well with

- `alerts_peek` — non-mutating sibling.
- `network_get` / `logs_tail` — drill into the source via `sourceKind` + `sourceId`.
- `alerts_config` — turn off noisy rules instead of draining without acting.
- `alerts_clear` — bulk delete already-drained rows.

## Example

```
> network_status
< {alerts:{pendingTotal:5, pendingEvents:212, critical:1}}
> alerts_drain severityMin:"warning"
< {summary:"Drained 5 alert(s) session 14: 1 critical, 2 error, 2 warning.", ...}
> network_get id:"req-3"
```
