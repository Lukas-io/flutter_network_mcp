---
tool: alerts_config
description: Read or update alert detection rules. Tune the slow-request threshold or disable noisy rules.
when_to_use: When alerts are too noisy (disable rules), too sensitive (raise slowThresholdMs), or you want to confirm current settings.
---

## DO NOT USE THIS TOOL WHEN

- You're just trying to read the current config and could check it once at session start — call this once, not on every turn.
- You want to permanently change defaults across runs — this is per-process. Restart with `--disable alerts` to turn off detection entirely; rule toggles don't persist.
- You're trying to suppress alerts about a specific host — use `ignored_hosts` instead. The host filter happens before detection.
- You want to delete already-fired alerts — that's `network_query` with DELETE FROM alerts.

## Use this when

- The user complains "too many slow alerts" — raise `slowThresholdMs` (default 3000).
- 4xx alerts are noise (e.g., the app expects 404s as control flow) — disable `http_4xx`.
- You want to confirm whether log-keyword detection is on.

## How it works

`get:true` (default) reads the current `AlertRules` singleton state. `set:{slowThresholdMs?, rules?:{...}}` mutates it. Rules supported: `http_5xx`, `http_4xx`, `http_error`, `http_slow`, `log_keyword`, `flutter_error`.

Changes apply immediately to subsequent capture writer ticks and log events — there's no restart needed.

## Args

- `get` (bool, optional) — defaults to true if `set` not provided.
- `set` (object) — `{slowThresholdMs?: int, rules?: {http_5xx?: bool, ...}}`.

## Returns

```json
{
  "config": {
    "slowThresholdMs": 3000,
    "rules": {"http_5xx": true, "http_4xx": true, "http_error": true,
              "http_slow": true, "log_keyword": true, "flutter_error": true}
  }
}
```

## Pairs well with

- `alerts_drain` — after retuning, drain stale alerts so new ones reflect the new rules.
- `ignored_hosts` — when the right fix is filtering hosts, not rules.

## Example

```
> alerts_config set:{slowThresholdMs:5000, rules:{http_4xx:false}}
< {config:{slowThresholdMs:5000, rules:{http_4xx:false,...}}}
```
