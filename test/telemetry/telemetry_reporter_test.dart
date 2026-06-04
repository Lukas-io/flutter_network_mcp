import 'package:flutter_network_mcp/src/telemetry/telemetry_reporter.dart';
import 'package:test/test.dart';

void main() {
  group('buildTelemetryPayload', () {
    test('includes the required schema fields', () {
      final payload = buildTelemetryPayload(
        error: StateError('test failure'),
        stack: StackTrace.fromString('#0 main (package:foo/bar.dart:1:1)'),
        dataDir: '/tmp/test-machine-a',
      );

      expect(payload['version'], isA<String>());
      expect(payload['isAot'], isA<bool>());
      expect(payload['os'], isA<String>());
      expect(payload['dart'], isA<String>());
      expect(payload['errorClass'], 'StateError');
      expect(payload['errorMessage'], contains('test failure'));
      expect(payload['stackHead'], isA<List<String>>());
      expect((payload['stackHead'] as List<String>), isNotEmpty);
      expect(payload['signature'], isA<String>());
      expect((payload['signature'] as String).length, 12);
      expect(payload['machineHash'], isA<String>());
      expect((payload['machineHash'] as String).length, 24);
      expect(payload['reportedAt'], isA<String>());
    });

    test('errorMessage truncated past max chars', () {
      final longMessage = 'x' * 500;
      final payload = buildTelemetryPayload(
        error: ArgumentError(longMessage),
        stack: StackTrace.fromString('#0 a (package:b/c.dart:1:1)'),
        dataDir: '/tmp/test',
      );
      final msg = payload['errorMessage'] as String;
      expect(msg.length, lessThan(longMessage.length));
      expect(msg, contains('…('));
      expect(msg, contains(' chars)'));
    });

    test('stackHead has paths redacted', () {
      final stack = StackTrace.fromString(
        '#0 main (/Users/alice/StudioProjects/sanga_mobile/lib/main.dart:1:1)\n'
        '#1 other (/Users/alice/code/util.dart:5:1)',
      );
      final payload = buildTelemetryPayload(
        error: StateError('e'),
        stack: stack,
        dataDir: '/tmp/test',
      );
      final frames = payload['stackHead'] as List<String>;
      expect(frames.any((f) => f.contains('alice')), isFalse,
          reason: 'redactor must strip usernames');
      expect(frames.any((f) => f.contains('<project:sanga_mobile>')), isTrue);
    });

    test('signature stable across runs for the same error + stack', () {
      final p1 = buildTelemetryPayload(
        error: StateError('one'),
        stack: StackTrace.fromString('#0 a (package:f/b.dart:1:1)'),
        dataDir: '/tmp/m1',
      );
      final p2 = buildTelemetryPayload(
        error: StateError('one'),
        stack: StackTrace.fromString('#0 a (package:f/b.dart:1:1)'),
        dataDir: '/tmp/m2',
      );
      expect(p1['signature'], p2['signature'],
          reason: 'signature depends only on errorClass + top-3 frames');
    });

    test('signature differs when error class differs', () {
      final p1 = buildTelemetryPayload(
        error: StateError('x'),
        stack: StackTrace.fromString('#0 a (package:f/b.dart:1:1)'),
        dataDir: '/tmp/m',
      );
      final p2 = buildTelemetryPayload(
        error: ArgumentError('x'),
        stack: StackTrace.fromString('#0 a (package:f/b.dart:1:1)'),
        dataDir: '/tmp/m',
      );
      expect(p1['signature'], isNot(p2['signature']));
    });

    test('machineHash stable for the same dataDir', () {
      final p1 = buildTelemetryPayload(
        error: StateError('a'),
        stack: StackTrace.fromString('#0 (package:f/b.dart:1:1)'),
        dataDir: '/tmp/machine-A',
      );
      final p2 = buildTelemetryPayload(
        error: ArgumentError('different'),
        stack: StackTrace.fromString('#0 different (package:x/y.dart:9:9)'),
        dataDir: '/tmp/machine-A',
      );
      expect(p1['machineHash'], p2['machineHash'],
          reason: 'machineHash depends only on dataDir + salt');
    });

    test('machineHash differs for different dataDirs', () {
      final p1 = buildTelemetryPayload(
        error: StateError('a'),
        stack: StackTrace.fromString('#0 (package:f/b.dart:1:1)'),
        dataDir: '/tmp/machine-A',
      );
      final p2 = buildTelemetryPayload(
        error: StateError('a'),
        stack: StackTrace.fromString('#0 (package:f/b.dart:1:1)'),
        dataDir: '/tmp/machine-B',
      );
      expect(p1['machineHash'], isNot(p2['machineHash']));
    });

    test('payload contains NO username string from a homedir path', () {
      final stack = StackTrace.fromString(
        '#0 main (/Users/lukasio/foo/bar.dart:1:1)\n'
        '#1 other (/Users/lukasio/baz/qux.dart:5:1)',
      );
      final payload = buildTelemetryPayload(
        error: StateError('e'),
        stack: stack,
        dataDir: '/Users/lukasio/Library/Application Support/flutter_network_mcp',
      );
      // No leaked username anywhere except machineHash (which is HMAC'd).
      // Strip machineHash before checking (HMAC output is hex chars only;
      // the username string can't appear in it).
      for (final entry in payload.entries) {
        if (entry.key == 'machineHash') continue;
        final s = jsonEncodeSafe(entry.value);
        expect(s.contains('lukasio'), isFalse,
            reason: 'field "${entry.key}" leaked username');
      }
    });
  });
}

String jsonEncodeSafe(Object? v) {
  if (v is String) return v;
  if (v is List) return v.join('\n');
  return v.toString();
}
