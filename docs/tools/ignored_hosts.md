---
tool: ignored_hosts
description: Manage the host allowlist. The capture writer skips any HTTP request whose host matches an entry.
when_to_use: To filter out analytics, crash reporters, and noisy telemetry before they pollute the DB.
---

## DO NOT USE THIS TOOL WHEN

- You want to filter at read time, not capture time — use `network_list hostContains:` instead. This tool drops requests entirely; they won't even appear in history.
- You're trying to redact request bodies — this is an all-or-nothing host filter. For redaction, use `network_replay`'s redact flag or SQL UPDATE on `http_bodies`.
- The host has dynamic prefixes (e.g. `xyz123.cdn.example.com`) — this is exact-match on hostname. Add each variant, or filter at read time via `hostContains`.
- The session is already running and you're worried about history — entries take effect on the NEXT capture tick. Already-captured rows stay.

## Use this when

- Crashlytics / Sentry / mixpanel.com are filling the DB with noise.
- An always-on websocket heartbeat is masking the requests you care about.
- A specific microservice is too verbose during a focused investigation.

## How it works

`add`: insert into `ignored_hosts` and refresh the writer's in-memory set immediately. `remove`: delete and refresh. `list`: SELECT.

The capture writer checks `req.uri.host` against the set on every poll tick and skips upserts (and therefore alerts, FTS indexing, body backfill) for matching hosts.

## Args

- `action` (string, default `"list"`) — `"list"` | `"add"` | `"remove"`.
- `host` (string, required for add/remove) — exact hostname (no scheme, no port).
- `reason` (string, optional, add only) — note for your future self.

## Returns

```json
// action: list
{"count": 2, "hosts": [{"host":"...", "addedMs":..., "reason":"telemetry"}]}

// action: add
{"action":"add", "host":"...", "inserted": true}

// action: remove
{"action":"remove", "host":"...", "removed": true}
```

## Pairs well with

- `network_list` — confirm the noisy host is gone after adding.
- `alerts_config` — alternative way to reduce noise (toggle off rules).

## Example

```
> ignored_hosts action:add host:"app.crashlytics.com" reason:"telemetry"
< {inserted: true}
> network_list limit:10
< [<no crashlytics rows>]
```
