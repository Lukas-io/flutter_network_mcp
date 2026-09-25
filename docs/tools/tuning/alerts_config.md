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

Every call returns the current config of the `AlertRules` singleton. When `set` holds at least one valid value the call applies it first, then reports (`mutated:true`); without `set` it only reads. The `get` flag is accepted but has no effect: omitting `set` is what makes a call read-only.

`set:{slowThresholdMs?, retentionDays?, rules?:{...}}` mutates the singleton in place. Missing fields keep their values. Changes apply immediately to subsequent capture writer ticks and log events, no restart needed. Everything is per-process and resets on restart.

Every value in `set` is checked before anything changes. Valid values are applied and listed in `applied` (for example `["slowThresholdMs", "rules.http_4xx"]`). Invalid ones are skipped and listed in `rejected` as `{field, value, reason}`, each with a warning, and the summary ends with `Rejected N value(s): ...`: `slowThresholdMs` that is not an integer > 0, `retentionDays` that is not an integer >= 0, `rules` that is not an object, an unknown rule key, a rule value that is not a bool, and an unknown setting. When nothing in `set` is valid the call fails with `bad_argument` and changes nothing.

Rule keys: `http_5xx`, `http_4xx`, `http_error`, `http_slow`, `log_keyword`, `flutter_error`, `http_anomaly`. `http_anomaly` toggles the baseline-relative detector, which emits both the `http_anomaly` (latency) and `http_anomaly_errors` (error rate) alert kinds. Custom `alert_patterns` have no toggle here; remove them with `alert_patterns action:"remove"`.

`retentionDays` controls the alert retention sweep (first run about 8s after start, then hourly): alerts older than N days are deleted, except those of a currently attached session. 0 keeps alerts forever. The initial value comes from `FLUTTER_NETWORK_MCP_ALERT_RETENTION_DAYS` (default 14). The same sweep always caps pending alerts at 200 per session, dropping the oldest.

## Args

- `get` (bool, optional): accepted, no effect. Omit `set` to read.
- `set` (object, optional): `{slowThresholdMs?: int, retentionDays?: int, rules?: {<rule_key>: bool}}`.
  - `slowThresholdMs`: `http_slow` fires when the exchange takes longer than this (default 3000). Must be > 0.
  - `retentionDays`: alert retention window in days, 0 = keep forever. Must be >= 0.
  - `rules`: per-rule enable flags; omitted rules keep their state. A non-bool value or unknown key is rejected; the other values still apply.

## Returns

```json
{
  "summary": "Updated alert config: slowThresholdMs=5000, retention=14d, enabled=[http_5xx, http_error, http_slow, log_keyword, flutter_error, http_anomaly], disabled=[http_4xx].",
  "mutated": true,
  "applied": ["slowThresholdMs", "rules.http_4xx"],
  "config": {
    "slowThresholdMs": 5000,
    "retentionDays": 14,
    "rules": {"http_5xx":true, "http_4xx":false, "http_error":true, "http_slow":true, "log_keyword":true, "flutter_error":true, "http_anomaly":true}
  },
  "nextSteps": ["alerts_drain ... see what fires under the new config", "alerts_clear ... wipe alerts that predate this rule change"]
}
```

A read (no `set`) returns `mutated:false`, a summary like `"Alert config: slowThresholdMs=3000, retention=14d, 7/7 rule(s) enabled."` (`retention=off` when `retentionDays` is 0), and nextSteps pointing at `alerts_config set:{...}` and `alert_patterns action:list`.

`warnings` appears when a value was rejected, all rules are off (the pipeline surfaces nothing), or `slowThresholdMs` < 500 (noisy). `applied` is present whenever `set` was passed; `rejected` only when something was rejected.

Errors (`errorKind: "bad_argument"`, nothing changed): `set` that is not an object, or a `set` in which every value was rejected (the reply carries `rejected` with the reasons and nextSteps to re-read the config and retry).

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
