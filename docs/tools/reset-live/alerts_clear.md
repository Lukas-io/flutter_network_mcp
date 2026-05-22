---
tool: alerts_clear
description: Permanently delete alert rows from the DB. Safe-by-default (drained-only); requires confirm:true to delete undrained.
when_to_use: When the alerts table is large with old already-handled rows you no longer need.
---

## DO NOT USE THIS TOOL WHEN

- You want to mark alerts as read — use `alerts_drain`. Clear permanently deletes; drain marks `drained=1`.
- Alerts are still pending and unread — `drainedOnly:false` deletes them with no chance to review; the tool refuses unless you ALSO pass `confirm:true`.
- You want to disable rules — `alerts_config`. Clear doesn't affect what fires next.
- The whole session is no longer needed — `session_delete` cascades to alerts and saves a call.

## Use this when

- Periodic cleanup of drained alerts after acting on them.
- Resetting the alert queue between debugging sessions.

## How it works

`DELETE FROM alerts WHERE <filters>`. Default `drainedOnly:true` keeps unread alerts safe. Tool refuses `drainedOnly:false` unless `confirm:true` is also passed. Returns `remainingPending` (count of still-undrained alerts in scope) so you can confirm the queue is clean.

## Args

- `sessionId` (int, optional) — defaults to all sessions.
- `severityMin` (string, optional) — `"info"` | `"warning"` | `"error"` | `"critical"`.
- `drainedOnly` (bool, default true).
- `confirm` (bool, required when `drainedOnly:false`).

## Returns

```json
{
  "summary": "Deleted 17 alert(s) from drained only, session 14. 0 undrained still pending in scope.",
  "deleted": 17,
  "remainingPending": 0,
  "sessionId": 14,
  "severityMin": null,
  "drainedOnly": true,
  "nextSteps": [
    "alerts_peek — confirm clean state",
    "db_stats — see DB size impact"
  ]
}
```

`warnings: []` fires when undrained alerts were deleted, or when some still pend in scope.

## Pairs well with

- `alerts_drain` — drain first, clear later.
- `db_stats` — confirm `rowCounts.alerts` shrank.
- `db_vacuum` — reclaim disk space after large clears.

## Example

```
> alerts_drain
> # ... act on each ...
> alerts_clear
< {summary:"Deleted 17 alert(s)...", remainingPending:0}
```
