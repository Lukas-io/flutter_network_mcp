---
tool: session_configure
description: Set process-wide sticky default filters that logs_tail / network_list inherit when the arg is omitted.
when_to_use: When you'll run several logs_tail / network_list reads with the same filter and don't want to repeat it.
---

## DO NOT USE THIS TOOL WHEN

- You only need a filter for a single read — just pass it to `logs_tail` / `network_list` directly.
- You want a permanent, persisted config — these defaults are in-memory and reset on server restart.
- You want to filter what gets CAPTURED — this only filters what reads RETURN. Use `ignored_hosts` / `alerts_config` for capture-time tuning.

## Use this when

- You're investigating one app concern and every read wants the same lens: "only `[EventTracker]` logs at level ≥ 1000" or "only 4xx/5xx HTTP". Set it once here, then read without repeating the args.
- You keep re-typing the same `messageContains` / `statusMin` on consecutive calls.

## How it works

Holds a single in-memory set of default filters. `logs_tail` and `network_list` read them to fill any filter argument you omit. An argument you DO pass on a read always wins for that call (even passing it as `null` to mean "no filter this time"). Resets on process restart.

## Args

All optional. Pass a field to set it, pass it as `null` to unset just that field, `clear:true` to reset all, or no args to view the current defaults.

- `levelMin` (int) — default `logs_tail` levelMin.
- `loggerContains` (string) — default `logs_tail` loggerContains.
- `messageContains` (string | list) — default `logs_tail` messageContains (OR-matched).
- `source` (string) — default `logs_tail` source.
- `method` (string | list) — default `network_list` method(s).
- `hostContains` (string) — default `network_list` hostContains.
- `statusMin` / `statusMax` (int) — default `network_list` status bounds.
- `clear` (bool) — reset ALL sticky defaults.

## Returns

```json
{
  "summary": "Sticky defaults active (levelMin, messageContains). ...",
  "defaults": {"levelMin": 1000, "messageContains": ["[EventTracker]"]},
  "nextSteps": ["logs_tail — returns the filtered view now without repeating args", "..."]
}
```

## Example

```
> session_configure levelMin:1000 messageContains:["[EventTracker]"]
> logs_tail            # inherits levelMin + messageContains
> logs_tail levelMin:0 # this call overrides levelMin; messageContains still inherited
> session_configure clear:true
```
