import 'package:flutter_network_mcp/src/telemetry/usage_recorder.dart';
import 'package:test/test.dart';

/// #79 Phase 1: the privacy-safe + correlation logic of the usage recorder.
void main() {
  group('argKeysFrom (keys only, never values)', () {
    test('null / empty -> empty list', () {
      expect(UsageRecorder.argKeysFrom(null), isEmpty);
      expect(UsageRecorder.argKeysFrom(const {}), isEmpty);
    });

    test('returns sorted keys', () {
      expect(UsageRecorder.argKeysFrom({'b': 1, 'a': 2, 'c': 3}),
          ['a', 'b', 'c']);
    });

    test('VALUES never appear in the output (privacy)', () {
      final keys = UsageRecorder.argKeysFrom({
        'hostContains': 'secret.internal.example.com',
        'query': 'authorization-token-abc123',
      });
      expect(keys, ['hostContains', 'query']);
      expect(keys.join(), isNot(contains('secret')));
      expect(keys.join(), isNot(contains('abc123')));
    });
  });

  group('outcomeFrom', () {
    test('threw -> error', () {
      expect(UsageRecorder.outcomeFrom(threw: true, isError: false), 'error');
    });
    test('isError -> error', () {
      expect(UsageRecorder.outcomeFrom(threw: false, isError: true), 'error');
    });
    test('count:0 -> empty', () {
      expect(
        UsageRecorder.outcomeFrom(
            threw: false, isError: false, structured: {'count': 0}),
        'empty',
      );
    });
    test('count>0 -> ok', () {
      expect(
        UsageRecorder.outcomeFrom(
            threw: false, isError: false, structured: {'count': 5}),
        'ok',
      );
    });
    test('no count field -> ok', () {
      expect(
        UsageRecorder.outcomeFrom(
            threw: false, isError: false, structured: {'foo': 1}),
        'ok',
      );
      expect(UsageRecorder.outcomeFrom(threw: false, isError: false), 'ok');
    });
  });

  group('correlationIdFor (gap-based turn rollover)', () {
    test('same turn within the gap, new turn after it', () {
      final r = UsageRecorder.config(enabled: true, gapMs: 1000);
      final a = r.correlationIdFor(1000);
      final b = r.correlationIdFor(1500); // +500, within gap
      final c = r.correlationIdFor(3000); // +1500 since last, past gap
      expect(a, b, reason: 'within the gap is one turn');
      expect(a, isNot(c), reason: 'past the gap rolls a new turn');
    });

    test('ids share the process token but increment the sequence', () {
      final r = UsageRecorder.config(enabled: true, gapMs: 1000);
      final a = r.correlationIdFor(0);
      final b = r.correlationIdFor(5000);
      // "<token>-<seq>"
      expect(a.split('-').first, b.split('-').first, reason: 'same token');
      expect(a.split('-').last, '1');
      expect(b.split('-').last, '2');
    });
  });

  group('disabled recorder', () {
    test('config can disable', () {
      expect(UsageRecorder.config(enabled: false).enabled, isFalse);
    });
  });
}
