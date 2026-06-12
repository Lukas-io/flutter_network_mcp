import 'package:flutter_network_mcp/src/state/log_buffer.dart';
import 'package:test/test.dart';

/// #15 (messageContains) + #21 (configurable buffer) live-path coverage.
void main() {
  void push(LogBuffer b, String message, {int? level, String logger = ''}) {
    b.push(
      source: 'logging',
      timestampMs: 0,
      level: level,
      loggerName: logger,
      message: message,
    );
  }

  group('messageContains (#15)', () {
    test('case-insensitive substring on the message body (single term)', () {
      final b = LogBuffer(capacity: 100);
      push(b, '[EventTracker] aeon_transaction_started');
      push(b, '[KycTier] upgraded');
      push(b, 'unrelated line');
      final r = b.tail(messageContains: ['eventtracker']);
      expect(r, hasLength(1));
      expect(r.single.message, contains('EventTracker'));
    });

    test('list form OR-matches every term', () {
      final b = LogBuffer(capacity: 100);
      push(b, '[EventTracker] aeon_transaction_started');
      push(b, '[KycTier] upgraded');
      push(b, 'unrelated line');
      final r = b.tail(messageContains: ['EventTracker', 'KycTier']);
      expect(r, hasLength(2));
      expect(
        r.map((e) => e.message),
        everyElement(anyOf(contains('EventTracker'), contains('KycTier'))),
      );
    });

    test('composes with levelMin', () {
      final b = LogBuffer(capacity: 100);
      push(b, '[EventTracker] info', level: 800);
      push(b, '[EventTracker] severe', level: 1200);
      final r = b.tail(messageContains: ['EventTracker'], levelMin: 1000);
      expect(r, hasLength(1));
      expect(r.single.message, contains('severe'));
    });

    test('empty / whitespace-only terms are ignored (matches everything)', () {
      final b = LogBuffer(capacity: 100);
      push(b, 'a');
      push(b, 'b');
      expect(b.tail(messageContains: const []), hasLength(2));
      expect(b.tail(messageContains: ['', '  ']), hasLength(2));
    });
  });

  group('capacity (#21)', () {
    test('explicit capacity is respected and rotates oldest out', () {
      final b = LogBuffer(capacity: 50);
      expect(b.capacity, 50);
      for (var i = 0; i < 60; i++) {
        push(b, 'line$i');
      }
      expect(b.length, 50);
      final r = b.tail(limit: 100);
      expect(r.first.message, 'line59', reason: 'newest first');
      expect(r.map((e) => e.message), isNot(contains('line0')),
          reason: 'oldest rotated out');
    });
  });

  group('tail ordering', () {
    test('newest-first and respects limit', () {
      final b = LogBuffer(capacity: 100);
      for (var i = 0; i < 5; i++) {
        push(b, 'm$i');
      }
      expect(b.tail(limit: 2).map((e) => e.message), ['m4', 'm3']);
    });
  });
}
