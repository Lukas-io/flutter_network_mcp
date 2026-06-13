import 'dart:async';
import 'dart:io';

import 'package:flutter_network_mcp_hooks/flutter_network_mcp_hooks.dart';
import 'package:test/test.dart';

/// End-to-end validation of the interception path WITHOUT external network:
/// a local WebSocket echo server, a real `WebSocket.connect` client whose
/// socket is intercepted via IOOverrides, and an assertion that the tee
/// captured + decoded the frames in both directions.
void main() {
  late HttpServer server;
  late Uri wsUri;

  setUp(() async {
    RealtimeCapture.instance.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    wsUri = Uri.parse('ws://127.0.0.1:${server.port}/socket');
    server.listen((req) async {
      if (WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = await WebSocketTransformer.upgrade(req);
        ws.listen((msg) => ws.add('echo:$msg')); // echo back
      } else {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
      }
    });
  });

  tearDown(() async {
    FlutterNetworkMcpHooks.uninstall();
    await server.close(force: true);
    RealtimeCapture.instance.clear();
  });

  test('intercepts a real WebSocket and captures both directions', () async {
    FlutterNetworkMcpHooks.install();

    final ws = await WebSocket.connect(wsUri.toString());
    final echoed = Completer<String>();
    ws.listen((data) {
      if (!echoed.isCompleted) echoed.complete(data as String);
    });

    ws.add('hello-from-client');
    final reply = await echoed.future.timeout(const Duration(seconds: 5));
    expect(reply, 'echo:hello-from-client');
    await ws.close();

    // Give the capture a tick to flush the inbound frame.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final drained = RealtimeCapture.instance.drain();
    final connections = drained['connections'] as List;
    final frames = (drained['frames'] as List).cast<Map<String, Object?>>();

    expect(connections, isNotEmpty, reason: 'the upgraded WS was registered');
    expect((connections.first as Map)['path'], '/socket');

    final outbound = frames.where((f) => f['dir'] == 'out').toList();
    final inbound = frames.where((f) => f['dir'] == 'in').toList();

    expect(
      outbound.any((f) => f['preview'] == 'hello-from-client'),
      isTrue,
      reason: 'captured + unmasked the client-sent frame',
    );
    expect(
      inbound.any((f) => f['preview'] == 'echo:hello-from-client'),
      isTrue,
      reason: 'captured the server echo frame',
    );
  });

  test('the app still works normally with hooks installed (transparency)',
      () async {
    FlutterNetworkMcpHooks.install();
    final ws = await WebSocket.connect(wsUri.toString());
    final got = <String>[];
    final done = Completer<void>();
    ws.listen((d) {
      got.add(d as String);
      if (got.length == 2) done.complete();
    });
    ws.add('one');
    ws.add('two');
    await done.future.timeout(const Duration(seconds: 5));
    expect(got, ['echo:one', 'echo:two']);
    await ws.close();
  });
}
