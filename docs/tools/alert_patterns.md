---
tool: alert_patterns
description: Add project-specific regex patterns the alert detector evaluates against every log message.
when_to_use: When built-in alert rules miss project-specific failure signals you want to catch automatically.
---

## DO NOT USE THIS TOOL WHEN

- Built-ins already catch it — `log_keyword` matches `/error|exception|failed|denied|timeout|refused|crash/i`, `flutter_error` catches the Flutter framework patterns. Don't double-fire.
- The pattern matches everything — `.*` style regexes flood the queue. The tool warns on these but still accepts; consider narrowing.
- The regex is invalid — the tool validates compile-time and returns a clear FormatException.
- You want HTTP-side rules — these match LOG text, not HTTP requests. For HTTP tuning use `alerts_config`.

## Use this when

- A specific service prefix appears in logs when things break: `\[OrderService\].*fail`.
- A custom error class name shows up: `MyAppCriticalError`.
- A frontend rendering signal needs flagging: `image cache exceeded`.

## How it works

Stored in `alert_patterns(id, kind, regex, severity, label)`. The detector evaluates them on every log record AFTER built-in rules. Patterns can fire ALONGSIDE `log_keyword`; they do NOT fire alongside `flutter_error` (that short-circuits to avoid double-alerts on framework exceptions).

`regex` compiles with `multiLine:true`. `label` becomes the alert title; if omitted, the first matching line is used. `kind` is your free-text label that shows in `alerts_drain.alerts[].kind`.

Patterns are hydrated from the DB on server start, so they survive restarts.

## Args

- `action` (string, default `"list"`) — `"list"` | `"add"` | `"remove"`.
- `kind` (string, required for add).
- `regex` (string, required for add) — Dart RegExp syntax.
- `severity` (string, required for add) — `"info"` | `"warning"` | `"error"` | `"critical"`.
- `label` (string, optional, add only).
- `id` (int, required for remove).

## Returns

```json
// list
{"action":"list", "summary":"2 custom alert pattern(s) registered.",
 "count":2, "patterns":[
   {"id":1, "kind":"order_fail", "regex":"OrderService.*fail",
    "severity":"error", "label":"OrderService failure", "addedMs":...}
 ],
 "nextSteps":["alerts_drain — see which patterns are firing", ...]}

// add
{"action":"add", "summary":"Registered alert pattern #1 (kind=order_fail, severity=error).",
 "id":1, "kind":"order_fail", "severity":"error",
 "nextSteps":["alerts_drain — wait for matching log records, then drain to confirm fires", ...]}

// remove
{"action":"remove", "summary":"Removed alert pattern #1.",
 "id":1, "removed":true,
 "nextSteps":["alert_patterns action:\"list\" — confirm remaining patterns", ...]}
```

`warnings: []` fires when the regex is over-broad (`.*` / `.+`).

## Pairs well with

- `alerts_drain` — confirm the new pattern fires.
- `alerts_config` — toggle built-in rules off if your custom pattern subsumes them.
- `alerts_clear` — wipe alerts already fired by a pattern you remove.

## Example

```
> alert_patterns action:"add" kind:"order_fail" regex:"OrderService.*fail" severity:"error" label:"OrderService failure"
< {summary:"Registered alert pattern #1...", id:1}
> # OrderService error logs ...
> alerts_drain
< [{kind:"order_fail", severity:"error", title:"OrderService failure", ...}]
```
