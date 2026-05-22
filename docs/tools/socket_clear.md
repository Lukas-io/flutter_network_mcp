---
tool: socket_clear
description: Wipe captured socket statistics on the attached isolate.
when_to_use: Before triggering a specific action and you want a clean socket profile.
---

## DO NOT USE THIS TOOL WHEN

- You're viewing history — this only affects the live VM profile, not the DB.
- You want to delete the `socket_events` rows — use `network_query` with DELETE.
- Socket profiling isn't enabled.

## Use this when

- Isolating sockets created by a specific user action.

## Args

None.

## Returns

```json
{"cleared": true}
```

## Pairs well with

- `socket_list` — verify empty afterwards.

## Example

```
> socket_clear
> # trigger the action
> socket_list
```
