---
tool: logs_clear
description: Empty the in-memory log ring buffer.
when_to_use: Before triggering an action when you want only that action's log output in the live buffer.
---

## DO NOT USE THIS TOOL WHEN

- You think this deletes history — it doesn't. The DB rows in `log_records` remain.
- You're viewing history — irrelevant; this only touches the live ring buffer.
- You want to stop capturing logs — there's no pause. Detach + reattach with `--disable logs`.

## Use this when

- Setting up a clean slate to isolate one action's log output.

## Args

None.

## Returns

```json
{"cleared": true}
```

## Pairs well with

- `logs_tail` — verify empty afterwards.

## Example

```
> logs_clear
> # trigger action
> logs_tail limit:50
```
