---
tool: alerts_drain
description: Return AND clear pending alerts (newest-first). Use at the top of an investigation.
when_to_use: At the start of any debugging turn — it surfaces issues the server already detected so you don't have to ask.
---

## DO NOT USE THIS TOOL WHEN

- You haven't attached and there's no viewed session — there's nothing to drain.
- You want to look without committing — use `alerts_peek` instead. Drain marks the alerts as seen, so a second call returns empty.
- The user wants you to keep ignoring noisy alerts — tune them via `alerts_config` (disable rules or raise `slowThresholdMs`), not by draining without acting.
- You're polling more than ~once a turn — alerts only fire on capture-writer ticks (every 2s); higher polling rates won't surface anything new.

## Use this when

- Starting a debugging conversation — call this first if `network_status.alerts.pending > 0`.
- After triggering a user action — drain to see what fired.
- Periodically during a long investigation to catch new issues.

## How it works

Selects rows from `alerts` where `drained=0`, optionally filtered by `severityMin` (info < warning < error < critical), then marks them drained. Returns one shot of the queue.

## Args

- `sessionId` (int, optional) — defaults to current session.
- `severityMin` (string) — `"info"` | `"warning"` | `"error"` | `"critical"`.
- `limit` (int, default 50, hard cap 200).

## Returns

```json
{
  "sessionId": 14,
  "count": 5,
  "alerts": [
    {"id":42, "severity":"critical", "kind":"flutter_error",
     "title":"Null check operator used on a null value",
     "detail":"...", "sourceKind":"log", "sourceId":"log:101", "tsMs":...}
  ]
}
```

Alert `kind` values: `http_5xx`, `http_4xx`, `http_error`, `http_slow`, `log_keyword`, `flutter_error`.

## Pairs well with

- `alerts_peek` — non-mutating sibling.
- `network_get` / `logs_tail` — drill into the source via `sourceKind` + `sourceId`.
- `alerts_config` — turn off noisy rules instead of draining without acting.

## Example

```
> network_status
< {alerts:{pending:5, critical:1}}
> alerts_drain severityMin:warning
< [5 alerts including a flutter_error]
> network_get id:<sourceId of the http alert>
```
