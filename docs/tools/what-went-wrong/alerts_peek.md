---
tool: alerts_peek
description: Read pending alerts WITHOUT marking drained. Identical shape to alerts_drain.
when_to_use: To see what's queued when you aren't ready to commit to "I've handled this".
---

## DO NOT USE THIS TOOL WHEN

- You're going to act on the alerts — use `alerts_drain`. Peek leaves them pending, so the next `network_status` still shows them.
- You want all of them — peek defaults to limit 20. Pass `limit:200` or use `network_query` for full enumeration.
- You're trying to track "what I've seen" — peek can't know that. Use `alerts_drain` to remove from queue, or SQL with `WHERE id > <your-last-seen>`.

## Use this when

- Triaging — "is there anything in the queue?" without disturbing it.
- Showing the user a summary before they decide what to investigate.
- Confirming `alerts_config` changes — peek before/after drain to compare.

## How it works

Same builder as `alerts_drain` but doesn't update `drained`. Response shape is identical (summary, breakdown, nextSteps point at drill-in tools + "alerts_drain — same data but marks them seen"). Each row carries the same dedup fields as `alerts_drain` — `occurrenceCount`, `firstSeenMs`, `lastSeenMs`, `lastSourceId`, `signature` — so a peek shows you the same burst-collapsed view a drain would. See the `alerts_drain` doc for the signature-based dedup design (RenderFlex × 200 → one row with `occurrenceCount: 200`).

## Args

Same as `alerts_drain` (`sessionId`, `appNameContains`, `severityMin`, `limit`) but smaller default `limit`: 20 instead of 50, hard cap 200, values <= 0 fall back to 20.

## Returns

Identical shape to `alerts_drain` (see that doc), with the summary starting `Peeked at N alert(s)`. `count` and the summary cover only the rows returned (at most `limit`), not everything pending; `network_status.alerts.pendingTotal` gives the DB-wide pending count.

Errors match `alerts_drain`: scope errors return `no_session` or `bad_argument` with `nextSteps`; an unknown `severityMin` returns `errorKind: "bad_argument"` naming the valid values; a DB failure returns `errorKind: "internal"` (`alerts_peek failed: ...`).

## Pairs well with

- `alerts_drain` — when you decide to handle them.
- `network_status` — `alerts.pendingTotal` count gives you the gist before peeking.

## Example

```
> alerts_peek limit:5
< {summary:"Peeked at 5 alert(s) session 14: 1 critical, 4 warning.", count:5, alerts:[<5 newest>]}
> # show user, get confirmation
> alerts_drain
```
