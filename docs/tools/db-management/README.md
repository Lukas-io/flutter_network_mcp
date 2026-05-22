# Managing the persistent DB

The DB grows forever unless you prune. These tools inspect size and remove rows. **All destructive tools default to dry-run; pass `confirm:true` to commit.**

- [`db_stats`](db_stats.md) — file size, row counts, body BLOB bytes, journal mode, pending alerts.
- [`bodies_purge`](bodies_purge.md) — drop request/response BLOBs; keep metadata. Per-session or per-time.
- [`session_delete`](session_delete.md) — remove a session + all its data. Cascades.
- [`db_vacuum`](db_vacuum.md) — reclaim disk space after the above. Run last.
