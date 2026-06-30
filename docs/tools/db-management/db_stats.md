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

Sums `page_count * page_size` for file size, `SUM(size)` from `http_bodies` for body BLOB total, COUNT(*) per table. Reads `PRAGMA journal_mode` and the undrained-alerts count. The `summary` line synthesizes the key numbers in one sentence; `warnings` fire on big-DB thresholds.

**Rolling size cap (#58).** A `sizeCap` block reports the auto-eviction cap (default ~2 GB, `FLUTTER_NETWORK_MCP_MAX_DB_BYTES`, `0`/`off` disables). When the DB exceeds the cap a low-frequency watchdog evicts OLDEST-first — bodies, then logs, then whole sessions — never touching the currently-attached session(s). The most recent sweep shows up as `lastEviction: {bytesFreed, bodiesDropped, logsDropped, sessionsDropped, oldestRetainedMs}` so the loss is visible, never silent. With the cap on, the manual-cleanup warnings stay quiet — you only see them if you turn it off.

## Args

None.

## Returns

```json
{
  "summary": "DB at 45.20 MB across 3 session(s) (38.10 MB in bodies, 0 undrained alert(s)).",
  "path": "/Users/me/.local/share/flutter_network_mcp/captures.db",
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
  "lastEviction": {"bytesFreed": 4841472, "bodiesDropped": 30, "logsDropped": 0, "sessionsDropped": 1, "oldestRetainedMs": 1782738710015, "atMs": 1782738714136},
  "warnings": [
    "DB is 45.20 MB — consider bodies_purge / session_delete + db_vacuum to shrink.",
    "Bodies are 84% of the DB — bodies_purge is the highest-impact cleanup."
  ],
  "nextSteps": [
    "session_list — see which sessions are eating space",
    "bodies_purge sessionId:<n> confirm:true — drop large BLOBs",
    "db_vacuum — reclaim disk space after deletes"
  ]
}
```

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
