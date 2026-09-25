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

`DELETE FROM alerts WHERE <filters>` for ONE session. The session resolves like the read tools: `sessionId`, else `appNameContains` (attached sessions only), else the `session_open` view, else the sole attached session, else a default pick among several attached. Historical sessions work too (pass `sessionId` or `session_open` them). There is no all-sessions mode; `session_delete` removes a whole session's alerts, and alert retention (see `db_stats`) expires old ones.

Default `drainedOnly:true` keeps unread alerts safe. Tool refuses `drainedOnly:false` unless `confirm:true` is also passed. Returns `remainingPending` (count of still-undrained alerts in scope, with the same `severityMin`) so you can confirm the queue is clean.

## Args

- `sessionId` (int, optional): session to clear. Omit to auto-resolve (see above). Not checked for existence; an unknown id deletes nothing.
- `appNameContains` (string, optional): pick an attached session by app-name substring instead of `sessionId`; must match exactly one.
- `severityMin` (string, optional): `"info"` | `"warning"` | `"error"` | `"critical"`. Deletes that severity and above.
- `drainedOnly` (bool, default true): only delete alerts already returned by `alerts_drain`.
- `confirm` (bool, default false): required when `drainedOnly:false`.

## Returns

```json
{
  "scope": {"sessionId": 14, "appName": "eats_mobile", "isLive": true},
  "summary": "Deleted 17 alert(s) from session 14 (eats_mobile), drained only. 0 undrained still pending in scope.",
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

`warnings` fires whenever `drainedOnly:false` was used (undrained alerts are gone permanently), and when undrained alerts still pend in scope. The first nextStep is `alerts_drain` when some still pend, otherwise `alerts_peek`.

Errors: `drainedOnly:false` without `confirm:true` returns `bad_argument` (nextSteps: `alerts_drain` first, or retry with `confirm:true`). An unknown `severityMin` value returns `bad_argument` naming the valid values, and nothing is deleted. Scope failures return `no_session` (nothing attached or opened, or no attached session matches `appNameContains`) or `bad_argument` (several attached sessions match), with `nextSteps`.

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
