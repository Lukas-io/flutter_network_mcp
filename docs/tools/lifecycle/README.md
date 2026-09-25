# Lifecycle tools

Always available regardless of `--capabilities`. The bookends of any session.

- [`network_status`](network_status.md): auto-orienting first call. Reports attachment state, available apps, pending alerts, DB context.
- [`network_discover_dtd`](network_discover_dtd.md): list the DTD instances on this machine from the standard `package:dtd` discovery directory.
- [`network_attach`](network_attach.md): open a capture session against a running app. Several apps can be attached at once.
- [`network_wait_for_app`](network_wait_for_app.md): wait for an app that is still launching to register, then attach to it.
- [`network_detach`](network_detach.md): stop capturing and end the session's DB row (unless another server process still captures into it). Captured data remains queryable.
- [`auto_attach_config`](auto_attach_config.md): read or change the persistent auto-attach allowlist, after the user confirms.
- [`report_issue`](report_issue.md): file a GitHub issue against this MCP (bug or UX friction).
