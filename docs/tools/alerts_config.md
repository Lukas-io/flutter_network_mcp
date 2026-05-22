---
tool: alerts_config
description: Read or update alert detection rules. Tune slow-request threshold or disable noisy rules at runtime.
when_to_use: When alerts are too noisy (disable rules), too sensitive (raise slowThresholdMs), or to confirm current settings.
---

## DO NOT USE THIS TOOL WHEN

- You're just reading config and could check once at session start — call this once, not per turn.
- You want to permanently change defaults across runs — this is per-process. Rule toggles don't persist; capability gating via `--disable alerts` is the persistent way to turn the pipeline off.
- You're trying to suppress alerts about a specific host — use `ignored_hosts` (host filter runs BEFORE detection).
- You want to delete already-fired alerts — that's `alerts_clear`.

## Use this when

- "Too many slow alerts" — raise `slowThresholdMs` (default 3000).
- 4xx alerts are control-flow noise — disable `http_4xx`.
- Confirming whether log-keyword detection is on.
- After mutation, check current state via the same call.

## How it works

`get` (default when `set` not given) reads the `AlertRules` singleton.
`set:{slowThresholdMs?, rules?:{...}}` mutates the singleton in place. Missing fields keep their values. Changes apply IMMEDIATELY to subsequent capture writer ticks and log events — no restart needed.

Rule keys: `http_5xx`, `http_4xx`, `http_error`, `http_slow`, `log_keyword`, `flutter_error`.

## Args

- `get` (bool, optional, default true when `set` omitted).
- `set` (object, optional) — `{slowThresholdMs?: int, rules?: {<rule_key>: bool}}`.

## Returns

```json
{
  "summary": "Updated alert config: slowThresholdMs=5000, enabled=[http_5xx, http_error, log_keyword, flutter_error], disabled=[http_4xx, http_slow].",
  "mutated": true,
  "config": {
    "slowThresholdMs": 5000,
    "rules": {"http_5xx":true, "http_4xx":false, ...}
  },
  "nextSteps": [
    "alerts_drain — see what fires under the new config",
    "alerts_clear — wipe alerts that predate this rule change"
  ]
}
```

`warnings: []` fires when all rules are off (pipeline silent) or `slowThresholdMs` < 500 (noisy).

## Pairs well with

- `alerts_drain` — after retuning, drain stale alerts so new ones reflect new rules.
- `alerts_clear` — bulk-delete drained alerts that no longer apply.
- `ignored_hosts` — when the right fix is filtering hosts, not rules.
- `alert_patterns` — for project-specific regex rules.

## Example

```
> alerts_config set:{slowThresholdMs:5000, rules:{http_4xx:false}}
< {summary:"Updated alert config: slowThresholdMs=5000...", config:{...}}
```
