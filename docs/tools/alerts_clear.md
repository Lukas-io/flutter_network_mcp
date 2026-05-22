---
tool: alerts_clear
description: Delete alert rows from the DB. By default only removes already-drained alerts.
when_to_use: When the alerts table is large with old already-handled rows you no longer need.
---

## DO NOT USE THIS TOOL WHEN

- You want to mark alerts as read — use `alerts_drain`. Clear permanently deletes; drain marks `drained=1`.
- The alerts are still pending and unread (`drained=0`) — passing `drainedOnly:false` deletes them outright, no chance to review. Drain them first or use `alerts_peek`.
- You want to delete alerts for a deleted session — already handled. `session_delete` cascades to alerts.
- You expect this to disable the rules — it doesn't. New alerts will fire again on the same events. Use `alerts_config` to toggle rules.

## Use this when

- Periodic cleanup of drained alerts after they've been acted on.
- Resetting the alert queue between debugging sessions.

## How it works

`DELETE FROM alerts WHERE <filter>`. Default filter is `drained = 1` (already-seen alerts). Optional filters: `sessionId`, `severityMin`.

## Args

- `sessionId` (int, optional).
- `severityMin` (string, optional) — `"info"` | `"warning"` | `"error"` | `"critical"`.
- `drainedOnly` (bool, default true).

## Returns

```json
{"deleted":4, "sessionId":null, "severityMin":null, "drainedOnly":true}
```

## Pairs well with

- `alerts_drain` — drain first, clear later.
- `db_stats` — confirm `rowCounts.alerts` shrank.

## Example

```
> alerts_drain
> # ... act on each alert ...
> alerts_clear
< {deleted: 17, drainedOnly: true}
```
