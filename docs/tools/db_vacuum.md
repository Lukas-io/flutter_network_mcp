---
tool: db_vacuum
description: WAL checkpoint + VACUUM + PRAGMA optimize. Reclaims disk space after bulk deletes.
when_to_use: After session_delete, bodies_purge, or alerts_clear when you actually want the file to shrink on disk.
---

## DO NOT USE THIS TOOL WHEN

- You haven't deleted anything recently — vacuum on a healthy DB is wasted work.
- The DB is large because of LIVE data — vacuum can't shrink it. You need to delete first.
- A capture session is actively writing — vacuum acquires an exclusive lock briefly. Probably fine on a small DB; consider detaching first if writes are heavy.
- You expect this to also optimize queries — that's what indexes are for. Vacuum is purely about disk layout. `PRAGMA optimize` is included but it's incremental.

## Use this when

- After `session_delete` and the file size didn't shrink (it won't until vacuum runs).
- After a `bodies_purge`.
- Periodically if `db_stats` shows the file growing without proportional row growth.

## How it works

1. `PRAGMA wal_checkpoint(TRUNCATE)` — drains the WAL into the main file.
2. `VACUUM` — rebuilds the database to reclaim freed pages.
3. `PRAGMA optimize` — runs SQLite's incremental optimizer.

Returns before/after byte sizes.

## Args

None.

## Returns

```json
{"vacuumed":true, "beforeBytes":5242880, "afterBytes":1048576,
 "beforeMb":"5.00", "afterMb":"1.00"}
```

## Pairs well with

- `session_delete` / `bodies_purge` — vacuum runs AFTER deletion to actually free space.
- `db_stats` — confirm the new size.

## Example

```
> bodies_purge olderThanMs:1700000000000 confirm:true
< {purgedBodies:1842}
> db_vacuum
< {beforeMb:"45.20", afterMb:"7.10"}
```
