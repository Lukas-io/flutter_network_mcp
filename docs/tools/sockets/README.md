# Sockets (non-HTTP traffic)

`dart:io` socket statistics — TCP/UDP byte counts and lifetimes. No payloads (sockets don't capture them). Useful for WebSockets, gRPC, custom TCP/UDP.

- [`socket_list`](socket_list.md) — list captured sockets, sorted newest-first.
- [`socket_get`](socket_get.md) — detail for one socket id.

To wipe the live socket profile, see [`reset-live/socket_clear`](../reset-live/socket_clear.md).
