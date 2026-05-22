---
tool: db_vacuum
description: WAL checkpoint + VACUUM + PRAGMA optimize. Reclaims disk space after bulk deletes.
when_to_use: After session_delete, bodies_purge, or alerts_clear when you actually want the file to shrink on disk.
---

## DO NOT USE THIS TOOL WHEN

- You haven't deleted anything recently — vacuum on a healthy DB is wasted work. Tool will surface a warning.
- DB is large because of LIVE data — vacuum can't shrink it. Delete first.
- A capture writer is actively writing — vacuum briefly acquires an exclusive lock. On small DBs probably fine; consider detaching first for heavy traffic.
- You expect query optimization — that's what indexes are for. Vacuum is about disk layout; `PRAGMA optimize` is incremental.

## Use this when

- After `session_delete` or `bodies_purge` and `db_stats` shows the file didn't shrink.
- Periodically if `db_stats` shows DB growing without proportional row growth.

## How it works

1. `PRAGMA wal_checkpoint(TRUNCATE)` — drains WAL into main file.
2. `VACUUM` — rebuilds the database to reclaim freed pages.
3. `PRAGMA optimize` — incremental SQLite optimizer.

Reports before/after byte sizes and the reclaimed delta in `summary`.

## Args

None.

## Returns

```json
{
  "summary": "Vacuumed: 45.20 MB → 7.10 MB (38.10 MB reclaimed).",
  "vacuumed": true,
  "beforeBytes": 47349760,
  "afterBytes": 7444070,
  "reclaimedBytes": 39905690,
  "beforeMb": "45.20",
  "afterMb": "7.10",
  "nextSteps": ["db_stats — confirm the new size"]
}
```

`warnings: []` fires when no space was reclaimed (suggests deletions are needed first).

## Pairs well with

- `session_delete` / `bodies_purge` / `alerts_clear` — vacuum runs AFTER to free space.
- `db_stats` — confirm the new size.

## Example

```
> bodies_purge olderThanMs:1700000000000 confirm:true
> db_vacuum
< {summary:"Vacuumed: 45.20 MB → 7.10 MB (38.10 MB reclaimed)."}
```
