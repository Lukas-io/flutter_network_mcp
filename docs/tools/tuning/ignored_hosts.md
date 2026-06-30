---
tool: ignored_hosts
description: Manage the capture skiplist (a denylist) of host or host/path globs. Capture writer skips matching HTTP requests at capture time.
when_to_use: To filter out analytics, crash reporters, noisy telemetry, or one chatty path BEFORE it pollutes the DB.
---

## DO NOT USE THIS TOOL WHEN

- You want to filter at READ time — use `network_list hostContains:` instead. This drops requests at CAPTURE time; they won't appear in history at all.
- You're trying to redact bodies — this is a host/path skip filter, not a masker. Use `redacted_headers` for header masking or SQL UPDATE for body redaction.
- The host has dynamic prefixes (`xyz123.cdn.example.com`) — a bare-host entry is exact-match. Use a glob (`*.cdn.example.com` is NOT supported, but `cdn.example.com/*` is) or filter at read time.
- The session is already running and you want existing rows gone — entries take effect on the next capture tick. Already-captured rows stay (a warning surfaces).

## Denylist vs allowlist (#64)

This tool manages the **denylist** (skiplist): matching requests are dropped. An entry with **no `/`** matches a whole host (the original behavior); an entry **with `/`** is a `host/path` glob (`*` = any chars, `?` = one char), so `dev.example.com/socket.io/*` silences just the socket.io polling while the REST API on the same host keeps flowing.

The opt-in **allowlist** is separate: set `FLUTTER_NETWORK_MCP_CAPTURE_ALLOW` (comma-separated host/path globs) at startup to capture ONLY matching requests and drop everything else — for focused debugging ("just `/stock/*`"). It is surfaced in this tool's `list` output as `captureAllowlist`. Deny still wins inside the allowed set.

## Use this when

- Crashlytics / Sentry / mixpanel are flooding the DB with noise.
- An always-on heartbeat is masking the requests you care about.
- A microservice is too verbose during a focused investigation.

## How it works

`add`: insert into `ignored_hosts`, refresh writer's in-memory set immediately. `remove`: delete + refresh. `list`: SELECT.

Writer builds a `CaptureFilter` from the entries on every refresh and checks each request's `host + path` against it on every poll tick, skipping upserts (and therefore alerts, FTS indexing, body backfill) for matching requests. The allowlist env is folded into the same filter.

## Args

- `action` (string, default `"list"`) — `"list"` | `"add"` | `"remove"`.
- `host` (string, required for add/remove) — a host (`analytics.example.com`) or host/path glob (`dev.example.com/socket.io/*`). No scheme, no port.
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
