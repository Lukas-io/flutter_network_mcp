# Resetting live state

**These do NOT touch the persistent DB.** They wipe live in-VM profiles / the in-memory log buffer / drained alert rows. For DB-side cleanup, see [`db-management/`](../db-management/).

- [`network_clear`](network_clear.md) — wipe the live HTTP profile on the attached isolate.
- [`socket_clear`](socket_clear.md) — wipe the live socket profile.
- [`logs_clear`](logs_clear.md) — empty the in-memory log ring buffer.
- [`alerts_clear`](alerts_clear.md) — delete drained alerts from the DB (the one exception that touches storage; safe-by-default).
