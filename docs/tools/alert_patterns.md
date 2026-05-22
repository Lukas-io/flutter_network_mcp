---
tool: alert_patterns
description: Add project-specific regex patterns the alert detector evaluates against every log message.
when_to_use: When the built-in alert rules miss project-specific failure signals you'd like to catch automatically.
---

## DO NOT USE THIS TOOL WHEN

- The built-in rules already catch it — log_keyword matches `/error|exception|failed|denied|timeout|refused|crash/i` and flutter_error catches FlutterError / RenderFlex / null-check / setState-after-dispose / Bad state. Don't double-fire.
- The pattern matches everything — overly broad regexes (`.*`) will alert on every log line and drown the queue. Test the regex on sample logs first.
- The regex is invalid — the tool validates compile-time, but if you can't write Dart RegExp syntax, simplify.
- You want HTTP-side patterns — these match log message text, not HTTP requests. For HTTP alert tuning use `alerts_config` (thresholds, rule toggles).

## Use this when

- A specific service prefix appears in logs when things go wrong: `\[OrderService\].*fail`.
- A custom error class name shows up: `MyAppCriticalError`.
- A frontend rendering pattern needs flagging: `image cache exceeded`.

## How it works

Stored in `alert_patterns(id, kind, regex, severity, label)`. The detector iterates these on every log record AFTER the built-in rules. Patterns can fire alongside `log_keyword` (both can match the same message); they do NOT fire alongside `flutter_error` (which short-circuits to avoid double-alerting on the same exception).

Regex is compiled with `multiLine:true`. `label` is used as the alert title; if omitted, the first matching line is used.

`kind` is your chosen label for the alert kind — appears in `alerts_drain` results so the agent can route on it.

## Args

- `action` (string, default `"list"`) — `"list"` | `"add"` | `"remove"`.
- `kind` (string, required for add) — your label, e.g. `order_fail`.
- `regex` (string, required for add) — Dart RegExp syntax.
- `severity` (string, required for add) — `"info"` | `"warning"` | `"error"` | `"critical"`.
- `label` (string, optional, add only) — alert title; defaults to the first matching line.
- `id` (int, required for remove).

## Returns

```json
// list
{"count":2, "patterns":[
  {"id":1, "kind":"order_fail", "regex":"OrderService.*fail",
   "severity":"error", "label":"OrderService failure", "addedMs":...}
]}

// add
{"action":"add", "id":1, "kind":"order_fail"}

// remove
{"action":"remove", "id":1, "removed":true}
```

## Pairs well with

- `alerts_drain` — confirm the new pattern fires.
- `alerts_config` — toggle built-in rules off if your custom pattern subsumes them.

## Example

```
> alert_patterns action:add kind:"order_fail" regex:"OrderService.*fail" severity:"error" label:"OrderService failure"
< {id:1}
> # an OrderService error logs ...
> alerts_drain
< [{kind:"order_fail", severity:"error", title:"OrderService failure", ...}]
```
