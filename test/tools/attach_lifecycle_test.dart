import 'package:dart_mcp/server.dart';
import 'package:flutter_network_mcp/src/tools/network_status.dart';
import 'package:flutter_network_mcp/src/server.dart' show kUnboundedTools;
import 'package:flutter_network_mcp/src/tools/network_wait_for_app.dart';
import 'package:test/test.dart';

/// #99: a reattach suggestion for a VM known dead must not survive; #98:
/// waiting for an app that never comes ends in a clear timeout.
void main() {
  group('continuationReattachStep (#99)', () {
    test('a live (not-dead) URI keeps the reattach suggestion', () {
      final step = continuationReattachStep(
        lastUri: 'ws://live',
        lastApp: 'sanga',
        attachedAgo: '1h',
        dead: false,
      );
      expect(step, contains('network_attach vmServiceUri:"ws://live"'));
      expect(step, contains('reattach'));
    });

    test('a dead URI with no relaunch says the app exited, not reattach', () {
      final step = continuationReattachStep(
        lastUri: 'ws://dead',
        lastApp: 'sanga',
        attachedAgo: '1h',
        exitedAgo: '2m',
        dead: true,
      );
      expect(step, contains('has exited ~2m ago'), reason: 'the exit age, not the attach age');
      expect(step, isNot(contains('network_attach vmServiceUri:"ws://dead"')));
      expect(step, contains('has exited'));
      expect(step, anyOf(contains('relaunch'), contains('wait_for_app')));
    });

    test('a dead URI whose app relaunched points at the new URI', () {
      final step = continuationReattachStep(
        lastUri: 'ws://dead',
        lastApp: 'sanga',
        dead: true,
        relaunchUri: 'ws://new',
      );
      expect(step, contains('network_attach vmServiceUri:"ws://new"'));
      expect(step, isNot(contains('ws://dead')));
    });
  });

  group('network_wait_for_app (#98)', () {
    test('is registered and deadline-exempt', () {
      expect(networkWaitForAppTool.name, 'network_wait_for_app');
      expect(kUnboundedTools, contains('network_wait_for_app'));
    });

    test('times out with errorKind timeout when no app registers', () async {
      final r = await networkWaitForApp(
        CallToolRequest(
            name: 'network_wait_for_app',
            arguments: const {'timeoutMs': 1000}),
        null,
      );
      final sc = r.structuredContent!;
      expect(r.isError, isTrue);
      expect(sc['errorKind'], 'timeout');
      expect(sc['polls'], greaterThanOrEqualTo(1));
    }, timeout: const Timeout(Duration(seconds: 20)));
  });
}
