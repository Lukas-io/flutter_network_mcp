# WebSockets

The app's WebSocket connections and their message timeline, with nothing added to the app. dart:io (Dart 3.13+, Flutter 3.47+) writes a timeline event for every connect, message, ping, pong, close and error. The server adds the VM's `Dart` timeline stream to what is recorded (keeping anything DevTools records) and reads those events.

Cost: with the `Dart` stream on, a debug build also records Flutter's frame events, as it does when DevTools' performance view is open. The server only reads the timeline when the socket byte counters moved (every WebSocket message moves them) or when `ws_list` / `ws_get` is called, so an animating app with no WebSocket traffic is not re-read every poll.

What you get: url, connect time, state, who closed it and with which code and reason, and for every message its time, direction, type (text or binary) and size. What you do not get: message contents. dart:io never puts them in the timeline.

- [`ws_list`](ws_list.md): the connections of a session, newest first, with counts and bytes each way.
- [`ws_get`](ws_get.md): one connection's event timeline, paged.

The HTTP upgrade request (status 101, with its headers) is in [`network_list`](../finding/network_list.md); the TCP byte counters are in [`socket_list`](../sockets/socket_list.md).
