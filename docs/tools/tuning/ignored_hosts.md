---
tool: ignored_hosts
description: Manage the capture skiplist (a denylist) of host or host/path globs. Capture writer skips matching HTTP requests at capture time.
when_to_use: To filter out analytics, crash reporters, noisy telemetry, or one chatty path BEFORE it pollutes the DB.
---

## DO NOT USE THIS TOOL WHEN

- You want to filter at READ time — use `network_list hostContains:` instead. This drops requests at CAPTURE time; they won't appear in history at all.
- You're trying to redact bodies: this is a host/path skip filter, not a masker. Use `redacted_headers` for header masking. Bodies cannot be edited in place (`network_query` is read-only); `bodies_purge` deletes stored bodies.
- The host has dynamic prefixes (`xyz123.cdn.example.com`) and you add a bare host: an entry without `/` is an exact host match and wildcards are not expanded, so `*.cdn.example.com` matches nothing. Add a glob with a path part instead (`*.cdn.example.com/*`), or filter at read time.
- The session is already running and you want existing rows gone — entries take effect on the next capture tick. Already-captured rows stay (a warning surfaces).

## Denylist vs allowlist (#64)

This tool manages the **denylist** (skiplist): matching requests are dropped. An entry with **no `/`** matches a whole host (the original behavior); an entry **with `/`** is a `host/path` glob (`*` = any chars, `?` = one char), so `dev.example.com/socket.io/*` silences just the socket.io polling while the REST API on the same host keeps flowing.

The **allowlist** is separate: the `capture_allow` tool (persistent) and the `GLINT_NETWORK_CAPTURE_ALLOW` startup env var (comma-separated) together capture ONLY matching requests and drop everything else, for focused debugging ("just `/stock/*`"). The union of both is surfaced in this tool's `list` output as `captureAllowlist`. Deny still wins inside the allowed set.

## Use this when

- Crashlytics / Sentry / mixpanel are flooding the DB with noise.
- An always-on heartbeat is masking the requests you care about.
- A microservice is too verbose during a focused investigation.

## How it works

`add`: insert into `ignored_hosts` (persistent across restarts), then refresh the filter of every attached session's capture writer immediately. `remove`: delete + refresh. `list`: reads the table plus the effective allowlist. Entries are stored as given; matching lowercases both sides, but `remove` needs the entry exactly as `list` shows it.

Writer builds a `CaptureFilter` from the entries on every refresh and checks each request's `host + path` (no scheme, port or query) against it on every poll tick, skipping upserts (and therefore alerts, FTS indexing, body backfill) for matching requests. A glob entry is anchored to the whole `host + path`, so `dev.example.com/socket.io` without a trailing `*` matches only that exact path. The allowlist (table + env) is folded into the same filter. Only HTTP requests are filtered; sockets and logs are unaffected.

## Args

- `action` (string, default `"list"`) — `"list"` | `"add"` | `"remove"`.
- `host` (string, required for add/remove) — a host (`analytics.example.com`) or host/path glob (`dev.example.com/socket.io/*`). No scheme, no port.
- `reason` (string, optional, add only).

## Returns

```json
// list
{"action":"list", "summary":"2 skiplist entr(ies) ... matching new captures are dropped.",
 "count":2,
 "hosts":[{"host":"app.crashlytics.com", "addedMs":..., "reason":"telemetry"}],
 "captureAllowlist":{"active":false, "patterns":[],
   "managedBy":"capture_allow tool (persistent) + GLINT_NETWORK_CAPTURE_ALLOW env"},
 "nextSteps":["network_list ... confirm noisy paths are no longer being captured", "network_query sql:\"SELECT host, COUNT(*) ...\" ... find noisy hosts to add"]}

// add (with already-captured rows)
{"action":"add", "summary":"Added \"app.crashlytics.com\" to ignored hosts. Capture writer refreshed.",
 "host":"app.crashlytics.com", "inserted":true,
 "warnings":["Already-captured rows for \"app.crashlytics.com\" (42 in history) are NOT removed. Only new captures are skipped."],
 "nextSteps":[...]}

// remove
{"action":"remove", "summary":"Removed \"app.crashlytics.com\" from ignored hosts. New requests will be captured again.",
 "host":"app.crashlytics.com", "removed":true, "nextSteps":[...]}
```

When the allowlist is active, `captureAllowlist` has `active:true`, the union of table and env patterns, and a `note`. With no entries the list summary reads `No skiplist entries. The writer captures every request.` (plus `that matches the allowlist` when one is active).

The already-captured warning counts rows across all sessions for an exact bare host only; a glob entry never produces it. Re-adding an existing entry returns `inserted:false` and refreshes its reason and timestamp. Removing an unknown entry succeeds with `removed:false`.

Errors: `bad_argument` for a missing `host` on add/remove or an unknown `action`; `internal` for anything else. Both carry `nextSteps`.

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
