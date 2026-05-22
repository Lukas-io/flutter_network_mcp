---
tool: ignored_hosts
description: Manage the host allowlist. Capture writer skips matching HTTP requests at capture time.
when_to_use: To filter out analytics, crash reporters, and noisy telemetry BEFORE they pollute the DB.
---

## DO NOT USE THIS TOOL WHEN

- You want to filter at READ time — use `network_list hostContains:` instead. This drops requests at CAPTURE time; they won't appear in history at all.
- You're trying to redact bodies — this is an all-or-nothing host filter. Use `redacted_headers` for header masking or SQL UPDATE for body redaction.
- The host has dynamic prefixes (`xyz123.cdn.example.com`) — this is exact-match. Add each variant or filter at read time.
- The session is already running and you want existing rows gone — entries take effect on the next capture tick. Already-captured rows stay (a warning surfaces).

## Use this when

- Crashlytics / Sentry / mixpanel are flooding the DB with noise.
- An always-on heartbeat is masking the requests you care about.
- A microservice is too verbose during a focused investigation.

## How it works

`add`: insert into `ignored_hosts`, refresh writer's in-memory set immediately. `remove`: delete + refresh. `list`: SELECT.

Writer checks `req.uri.host` against the set on every poll tick and skips upserts (and therefore alerts, FTS indexing, body backfill) for matching hosts.

## Args

- `action` (string, default `"list"`) — `"list"` | `"add"` | `"remove"`.
- `host` (string, required for add/remove) — exact hostname, no scheme, no port.
- `reason` (string, optional, add only).

## Returns

```json
// list
{"action":"list", "summary":"2 ignored host(s) — new captures from these hosts are skipped.",
 "count":2,
 "hosts":[{"host":"app.crashlytics.com", "addedMs":..., "reason":"telemetry"}],
 "nextSteps":["network_list — confirm noisy hosts are no longer being captured", ...]}

// add (with already-captured rows)
{"action":"add", "summary":"Added \"app.crashlytics.com\" to ignored hosts. Capture writer refreshed.",
 "host":"app.crashlytics.com", "inserted":true,
 "warnings":["Already-captured rows for \"app.crashlytics.com\" (42 in history) are NOT removed. Only new captures are skipped."],
 "nextSteps":[...]}

// remove
{"action":"remove", "summary":"Removed \"app.crashlytics.com\" from ignored hosts. New requests will be captured again.",
 "host":"app.crashlytics.com", "removed":true, "nextSteps":[...]}
```

## Pairs well with

- `network_list` — confirm filtering took effect.
- `alerts_config` — alternative noise reduction (toggle rules).
- `network_query "SELECT host, COUNT(*) ..."` — find noisy hosts to add.

## Example

```
> network_query sql:"SELECT host, COUNT(*) AS n FROM http_requests GROUP BY host ORDER BY 2 DESC"
< [{host:"app.crashlytics.com", n:847}]
> ignored_hosts action:"add" host:"app.crashlytics.com" reason:"telemetry"
< {summary:"Added \"app.crashlytics.com\"...", warnings:["847 in history..."]}
```
