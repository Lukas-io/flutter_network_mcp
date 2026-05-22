# Lifecycle tools

Always available regardless of `--capabilities`. The bookends of any session.

- [`network_status`](network_status.md) — auto-orienting first call. Reports attachment state, available apps, pending alerts, DB context.
- [`network_attach`](network_attach.md) — open a capture session against a running app.
- [`network_detach`](network_detach.md) — close the session, finalize the DB row. Captured data remains queryable.
