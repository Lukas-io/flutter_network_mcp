import 'dart:io';

import 'package:test/test.dart';

/// Spike: does WebSocket.connect resolve its HttpClient through
/// HttpOverrides.createHttpClient (the hook the detachSocket approach needs)?
bool _createCalled = false;

base class _SpyOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    _createCalled = true;
    return super.createHttpClient(context);
  }
}

void main() {
  test('WebSocket.connect goes through HttpOverrides.createHttpClient',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      if (WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = await WebSocketTransformer.upgrade(req);
        ws.listen((m) => ws.add('echo:$m'));
      }
    });

    final prev = HttpOverrides.current;
    HttpOverrides.global = _SpyOverrides();
    try {
      final ws = await WebSocket.connect('ws://127.0.0.1:${server.port}/x');
      ws.add('hi');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await ws.close();
    } finally {
      HttpOverrides.global = prev;
      await server.close(force: true);
    }

    expect(_createCalled, isTrue,
        reason: 'detachSocket interception is viable only if this hook fires');
  });
}
