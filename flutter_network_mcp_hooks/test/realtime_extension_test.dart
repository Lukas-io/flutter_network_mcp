import 'dart:typed_data';

import 'package:flutter_network_mcp_hooks/flutter_network_mcp_hooks.dart';
import 'package:test/test.dart';

void main() {
  setUp(() => RealtimeCapture.instance.clear());

  test('register() is idempotent', () {
    final first = RealtimeExtension.register();
    final second = RealtimeExtension.register();
    // In the JIT test VM the extension registers; either way the second call
    // must agree with the first and never throw.
    expect(second, equals(first));
  });

  test('drain payload reports connections + frames, then clears frames', () {
    final cap = RealtimeCapture.instance;
    final connId = cap.openConnection('echo.example', 443, '/socket');
    cap.recordMessage(
      connectionId: connId,
      outbound: true,
      opcode: WsOpcode.text,
      payload: Uint8List.fromList('{"event":"ping"}'.codeUnits),
      wasCompressed: false,
    );
    cap.recordMessage(
      connectionId: connId,
      outbound: false,
      opcode: WsOpcode.binary,
      payload: Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]),
      wasCompressed: true,
    );

    final payload = RealtimeExtension.buildPayload();
    expect(payload['ok'], isTrue);
    final connections = payload['connections'] as List;
    final frames = payload['frames'] as List;
    expect(connections, hasLength(1));
    expect(connections.first['host'], equals('echo.example'));
    expect(connections.first['path'], equals('/socket'));
    expect(frames, hasLength(2));
    expect(frames[0]['dir'], equals('out'));
    expect(frames[0]['preview'], contains('ping'));
    expect(frames[1]['dir'], equals('in'));
    expect(frames[1]['compressed'], isTrue);

    // Second drain: frames cleared, connection record retained so later
    // frames can still be attributed to the connection.
    final second = RealtimeExtension.buildPayload();
    expect(second['frames'], isEmpty);
    expect(second['connections'], hasLength(1));
  });

  test('clear payload wipes connections and frames', () {
    final cap = RealtimeCapture.instance;
    final connId = cap.openConnection('host', 80, '/');
    cap.recordMessage(
      connectionId: connId,
      outbound: true,
      opcode: WsOpcode.text,
      payload: Uint8List.fromList('hi'.codeUnits),
      wasCompressed: false,
    );

    final cleared = RealtimeExtension.buildPayload(clear: true);
    expect(cleared['cleared'], isTrue);

    final after = RealtimeExtension.buildPayload();
    expect(after['connections'], isEmpty);
    expect(after['frames'], isEmpty);
  });
}
