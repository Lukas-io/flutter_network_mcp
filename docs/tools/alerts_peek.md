---
tool: alerts_peek
description: Read pending alerts WITHOUT marking them drained.
when_to_use: When you want to see what's queued but aren't ready to commit to "I've handled this".
---

## DO NOT USE THIS TOOL WHEN

- You're going to act on the alerts — use `alerts_drain`. Peek leaves them as pending, which means the next `network_status` still shows them.
- You want all of them — peek defaults to limit 20. Pass `limit:200` or use `network_query` for a full enumeration.
- You're trying to dedupe alerts you've already seen — peek can't know what you've personally read. Use `alerts_drain` to remove from queue, or use SQL with `WHERE id > <last seen>`.

## Use this when

- Triaging: "is there anything in the queue?" without disturbing it.
- Showing the user a summary before they decide what to investigate.
- Confirming alerts_config changes — peek before drain to compare counts.

## How it works

Same as `alerts_drain` but doesn't update the `drained` flag.

## Args

- `sessionId` (int, optional).
- `severityMin` (string) — `"info"` | `"warning"` | `"error"` | `"critical"`.
- `limit` (int, default 20, hard cap 200).

## Returns

Identical shape to `alerts_drain`.

## Pairs well with

- `alerts_drain` — when you decide to handle them.
- `network_status` — `alerts.pending` count gives you the gist before you peek.

## Example

```
> alerts_peek limit:5
< {count: 12, alerts:[<first 5>]}
> # show user, get permission
> alerts_drain
```
