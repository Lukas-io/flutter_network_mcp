# flutter_network_mcp_hooks

Companion runtime hooks for [flutter_network_mcp](https://github.com/Lukas-io/flutter_network_mcp).

The Dart VM service profiler (`getHttpProfile`) stops at the HTTP upgrade, so
**everything after a WebSocket handshake is invisible** to flutter_network_mcp.
This package captures those frames inside your app and exposes them over a VM
service extension the MCP polls, so `ws_list` / `ws_get` can show real
WebSocket traffic (Socket.IO, GraphQL subscriptions, custom protocols).

It captures HTTP-upgraded `dart:io` WebSockets, including permessage-deflate
compressed frames (RFC 7692) and fragmented messages, which it reassembles and
decompresses before recording one row per logical message.

## Install

Add it as a `dev_dependency` (it must never ship in a release build):

```yaml
dev_dependencies:
  flutter_network_mcp_hooks: ^0.1.0
```

Call `install()` once, as early as possible in `main()`, guarded by
`kDebugMode` so it is tree-shaken out of release builds:

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_network_mcp_hooks/flutter_network_mcp_hooks.dart';

void main() {
  if (kDebugMode) FlutterNetworkMcpHooks.install();
  runApp(const MyApp());
}
```

That is the whole setup. Open a WebSocket, then ask the agent to run `ws_list`.

## How it works

`WebSocket.connect` (and libraries built on `dart:io`, like
`web_socket_channel` / `socket_io_client`) resolve their `HttpClient` through
`HttpOverrides`, upgrade over HTTP, then call `detachSocket()` for the raw
post-upgrade socket. `install()` wraps that chain and tees the detached
socket's bytes through a per-direction RFC 6455 frame decoder into a bounded
in-memory ring buffer.

The MCP drains the buffer over the `ext.flutter_network_mcp.getRealtimeProfile`
VM service extension (registered by `install()`), the same drain-on-poll
contract the SDK's own profilers use. Apps that do not install this package
expose no extension, so the MCP's WebSocket tables simply stay empty.

## Privacy and safety

- Debug-only: gate the call with `kDebugMode`. In release/AOT builds
  `registerExtension` is unavailable, so even a stray call is a no-op.
- Capture never throws into your app: every tee/decoder step is wrapped, so a
  malformed frame degrades capture, never your networking.
- Bounded memory: the ring buffer caps retained frames (default 2000) and
  connections (default 256), dropping oldest-first.
- Ping/pong keepalives are dropped; only data messages and close frames are
  recorded.
