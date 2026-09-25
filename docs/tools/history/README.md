# Investigating history

Past capture sessions stay in the SQLite DB until you [delete them](../db-management/session_delete.md) or the rolling size cap (default about 2 GB, see [`db_stats`](../db-management/db_stats.md)) evicts the oldest data. Several server processes attached to the same app share one session row. These tools navigate, view, annotate, and export sessions.

- [`session_list`](session_list.md) — past sessions with per-session counts (HTTP / sockets / logs).
- [`session_open`](session_open.md) — point the read tools at a past session.
- [`session_close`](session_close.md) — revert the read pointer to live.
- [`session_export`](session_export.md) — write a session to disk as HAR 1.2 or NDJSON.
- [`session_note`](session_note.md) — freeform note on a session (helps future-you find it).
