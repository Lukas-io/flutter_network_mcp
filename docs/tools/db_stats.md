---
tool: db_stats
description: Captures DB statistics — file size, table row counts, body bytes, WAL state.
when_to_use: When deciding whether to prune or vacuum, or to confirm a cleanup actually freed space.
---

## DO NOT USE THIS TOOL WHEN

- You want per-session row counts — `session_list` already returns those.
- You're polling on every turn — DB stats don't change minute-to-minute. Once per investigation is plenty.
- You expect to see anomalies in the schema — this tool reports row counts and disk size, not schema details.

## Use this when

- The DB file is suspected of being large; you want a quick size check.
- Before/after a `bodies_purge` or `session_delete` to verify cleanup.
- After `db_vacuum` to confirm space was reclaimed.

## How it works

Sums `page_count * page_size` for file size, `SUM(size)` from `http_bodies` for body BLOB total, COUNT(*) per table. Reads `PRAGMA journal_mode` and the undrained-alerts count.

## Args

None.

## Returns

```json
{
  "path": "/Users/me/.local/share/flutter_network_mcp/captures.db",
  "rowCounts": {"sessions":3, "http_requests":182, "http_bodies":156, ...},
  "sizeBytes": 5242880,
  "sizeMb": "5.00",
  "bodiesBytes": 3145728,
  "bodiesMb": "3.00",
  "pageSize": 4096,
  "pageCount": 1280,
  "journalMode": "wal",
  "pendingAlerts": 4
}
```

## Pairs well with

- `bodies_purge` — when `bodiesMb` is the bulk of the file.
- `session_delete` + `db_vacuum` — to shrink overall.
- `network_query` — for richer ad-hoc stats (e.g., bodies size per session).

## Example

```
> db_stats
< {sizeMb:"45.20", bodiesMb:"38.10", rowCounts:{...}}
> bodies_purge olderThanMs:1700000000000 confirm:true
> db_vacuum
> db_stats
< {sizeMb:"2.10", bodiesMb:"0.50"}
```
