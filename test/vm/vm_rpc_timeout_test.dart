import 'dart:async';

import 'package:flutter_network_mcp/src/vm/vm_client.dart';
import 'package:test/test.dart';

/// Root cause of the network_body 8-minute hang (telemetry): VM service RPCs
/// were unbounded awaits, so a live-but-unresponsive VM blocked the tool
/// forever. Every RPC is now bounded by a deadline at the VmClient layer.
void main() {
  group('bounded RPC deadline', () {
    test('a never-completing RPC throws VmRpcTimeoutException, not a hang', () {
      final neverCompletes = Completer<int>().future; // never resolves
      expect(
        () => VmClient.boundForTest(
          'getHttpProfileRequest',
          neverCompletes,
          deadline: const Duration(milliseconds: 50),
        ),
        throwsA(isA<VmRpcTimeoutException>()),
      );
    });

    test('the timeout error names the operation and is actionable', () async {
      try {
        await VmClient.boundForTest(
          'getHttpProfileRequest',
          Completer<int>().future,
          deadline: const Duration(milliseconds: 30),
        );
        fail('should have timed out');
      } on VmRpcTimeoutException catch (e) {
        expect(e.operation, 'getHttpProfileRequest');
        expect(e.toString(), contains('getHttpProfileRequest'));
        expect(e.toString().toLowerCase(), contains('paused'));
      }
    });

    test('a fast RPC well under the deadline returns its value normally', () async {
      final value = await VmClient.boundForTest(
        'getHttpProfile',
        Future.value(42),
        deadline: const Duration(seconds: 5),
      );
      expect(value, 42);
    });

    test('default deadline is a sane bound (10s), far above normal calls', () {
      // Normal RPCs run in single/double-digit ms per telemetry; the default
      // must be generous enough never to false-positive yet finite.
      expect(VmClient.rpcDeadline.inSeconds, greaterThanOrEqualTo(1));
      expect(VmClient.rpcDeadline.inSeconds, lessThanOrEqualTo(60));
    });
  });
}
