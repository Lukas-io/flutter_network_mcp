---
tool: alert_patterns
description: Add project-specific regex patterns the alert detector evaluates against every log message.
when_to_use: When built-in alert rules miss project-specific failure signals you want to catch automatically.
---

## DO NOT USE THIS TOOL WHEN

- Built-ins already catch it — `log_keyword` matches `/error|exception|failed|denied|timeout|refused|crash/i`, `flutter_error` catches the Flutter framework patterns. Don't double-fire.
- The pattern matches everything: a match-all regex floods the queue. The tool warns only when the regex is exactly `.*` or `.+` and still registers it; any other broad pattern is accepted without a warning.
- The regex is invalid: it is compiled before storing, and a bad one returns `errorKind: "bad_query"` with `Invalid regex: <reason>`. Nothing is stored.
- You want HTTP-side rules — these match LOG text, not HTTP requests. For HTTP tuning use `alerts_config`.

## Use this when

- A specific service prefix appears in logs when things break: `\[OrderService\].*fail`.
- A custom error class name shows up: `MyAppCriticalError`.
- A frontend rendering signal needs flagging: `image cache exceeded`.

## How it works

Stored in the `alert_patterns` table (`id`, `kind`, `regex`, `severity`, `label`, `added_at`); `kind` is trimmed before storing. Every add or remove reloads the full pattern set into the detector, so changes apply to the next log record.

The detector runs on each persisted `logging`, `stdout` and `stderr` record with a non-empty message (native device logs are not evaluated). It matches the record's `message` only; the separate `error` and `stackTrace` fields are not scanned. Built-in rules run first. If `flutter_error` is enabled and matches, the record stops there and no custom pattern is evaluated. Otherwise `log_keyword` and every matching custom pattern each raise their own alert, so one record can fire several.

`regex` compiles with `multiLine:true` and is case-sensitive (no case flag is set). A leading `(?i)` is rejected as an invalid regex; use a character class such as `[Oo]rder[Ss]ervice` instead. `label` becomes the alert title; if omitted, the first line of the message is used (cut at 160 chars). The alert `detail` is the message, cut at 2048 chars. `kind` is your free-text label that shows in `alerts_drain.alerts[].kind`, and it feeds the dedup signature together with the title.

`severity` is checked case-insensitively and stored lowercase (`"ERROR"` is stored and reported as `"error"`), so its alerts pass `alerts_drain` / `alerts_peek` / `alerts_clear` `severityMin` filters. Patterns stored in another case by an older version still fire and filter correctly.

Patterns are loaded from the DB on server start, so they survive restarts. The tool exists only when the `alerts` capability is enabled.

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

On `add`, `warnings` appears only when the regex is exactly `.*` or `.+`. On `remove` of an unknown id the call succeeds with `removed:false` and summary `No alert pattern with id <id> (already removed?).`. `label` is omitted from list entries that have none.

Errors (all carry `nextSteps`):
- `bad_argument`: missing `kind`, `regex` or `severity` on add, missing `id` on remove, an unknown `action`, or a severity outside info / warning / error / critical.
- `bad_query`: the regex does not compile.
- `internal`: any other failure.

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
< {summary:"Drained 1 alert(s) session 14: 1 error.", alerts:[{kind:"order_fail", severity:"error", title:"OrderService failure", ...}]}
```
