---
tool: db_stats
description: Captures DB statistics — file size, table row counts, body bytes, journal mode, pending alerts.
when_to_use: When deciding whether to prune or vacuum, or to confirm a cleanup actually freed space.
---

## DO NOT USE THIS TOOL WHEN

- You want per-session row counts — `session_list` already returns those.
- You're polling on every turn — DB stats don't change minute-to-minute. Once per investigation is plenty.
- You expect schema details — this returns counts and disk size, not schema.

## Use this when

- DB file is suspected of being large; quick size check.
- Before/after `bodies_purge` or `session_delete` to verify cleanup.
- After `db_vacuum` to confirm space reclaimed.

## How it works

Multiplies `PRAGMA page_count` by `page_size` for file size, sums `size` from `http_bodies` for the body BLOB total, and counts rows in `sessions`, `http_requests`, `http_bodies`, `socket_events`, `log_records`, `alerts`, `http_search_map`, `ignored_hosts`, `redacted_headers`, `alert_patterns` (a table that cannot be read reports `-1`). Reads `PRAGMA journal_mode` and the undrained-alerts count across the whole DB. The `summary` line synthesizes the key numbers in one sentence and ends with `(NO-PERSIST: in-memory only)` when the server runs with `--no-persist` (`ephemeral: true`).

Warnings: the DB is over 100 MB; bodies are over 70% of the file and over 5 MB; 50 or more sessions while the rolling cap is off. `nextSteps`: `session_list` (sessions capability), `bodies_purge` + `db_vacuum` when the DB is over 100 MB or bodies are over 70% of it (admin capability), `alerts_drain` when alerts are pending (alerts capability), else "No action needed".

**Rolling size cap (#58).** A `sizeCap` block reports the auto-eviction cap (default 2 GB, `FLUTTER_NETWORK_MCP_MAX_DB_BYTES` in bytes with a 1 MB floor, `0`/`off` disables; `maxBytes` / `maxMb` are omitted when off). When the DB exceeds the cap, a low-frequency watchdog evicts OLDEST-first (bodies, then logs, then whole sessions) down to about 90% of the cap and vacuums, never touching a session this server process is attached to or another live server process sharing the DB captures into. Evicted bodies also leave the search index (their URLs stay searchable). `lastEviction: {bytesFreed, bodiesDropped, logsDropped, sessionsDropped, oldestRetainedMs, atMs}` shows this process's most recent sweep that dropped something, so the loss is visible; it is absent until then and resets when the server restarts. With the cap on, only the many-sessions warning stays quiet; the size and bodies warnings still fire.

**Alert retention.** An `alertRetention: {days, enabled, note}` block reports alert auto-expiry: alerts older than `days` (default 14, `FLUTTER_NETWORK_MCP_ALERT_RETENTION_DAYS`) from sessions that are not attached are deleted hourly; `0` disables it (`alerts_config set:{retentionDays:N}`).

## Args

None.

## Returns

```json
{
  "summary": "DB at 45.20 MB across 3 session(s) (38.10 MB in bodies, 0 undrained alert(s)).",
  "path": "/Users/me/.local/share/flutter_network_mcp/captures.db",
  "ephemeral": false,
  "rowCounts": {"sessions":3, "http_requests":182, "http_bodies":156, ...},
  "sizeBytes": 47349760,
  "sizeMb": "45.20",
  "bodiesBytes": 39949107,
  "bodiesMb": "38.10",
  "pageSize": 4096,
  "pageCount": 11560,
  "journalMode": "wal",
  "pendingAlerts": 0,
  "sizeCap": {"enabled": true, "maxBytes": 2147483648, "maxMb": "2048", "env": "FLUTTER_NETWORK_MCP_MAX_DB_BYTES (0/off disables)"},
  "alertRetention": {"days": 14, "enabled": true, "note": "alerts from non-attached sessions older than 14d auto-expire hourly"},
  "lastEviction": {"bytesFreed": 4841472, "bodiesDropped": 30, "logsDropped": 0, "sessionsDropped": 1, "oldestRetainedMs": 1782738710015, "atMs": 1782738714136},
  "warnings": [
    "Bodies are 84% of the DB — bodies_purge is the highest-impact cleanup."
  ],
  "nextSteps": [
    "session_list — see which sessions are eating space",
    "bodies_purge sessionId:<n> confirm:true — drop large BLOBs",
    "db_vacuum — reclaim disk space after deletes"
  ]
}
```

Errors: an unexpected DB failure returns `errorKind: "internal"`.

## Pairs well with

- `bodies_purge` — when bodies dominate.
- `session_delete` + `db_vacuum` — full shrink path.
- `network_query` — for custom stats (e.g., bodies size per session).

## Example

```
> db_stats
< {summary:"DB at 45.20 MB across 3 session(s)...", warnings:[...], nextSteps:[...]}
> bodies_purge olderThanMs:1700000000000 confirm:true
> db_vacuum
> db_stats
< {summary:"DB at 2.10 MB across 3 session(s)..."}
```
