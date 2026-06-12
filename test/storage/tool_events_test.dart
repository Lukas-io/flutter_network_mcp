import 'dart:io';

import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:test/test.dart';

/// #79 Phase 1: the tool_events store (schema v7) round-trips and aggregates.
void main() {
  group('tool_events DAO', () {
    late Directory dir;
    late CapturesDao dao;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('tool_events_test_');
      CapturesDatabase.open(dataDir: dir.path);
      dao = CapturesDao();
    });

    tearDown(() {
      CapturesDatabase.instance.close();
      dir.deleteSync(recursive: true);
    });

    test('insert + count + arg_keys stored as JSON', () {
      dao.insertToolEvent(
        tsMs: 1000,
        correlationId: 'tok-1',
        tool: 'network_list',
        outcome: 'ok',
        argKeys: ['hostContains', 'statusMin'],
        durationMs: 42,
        resultBytes: 1840,
      );
      expect(dao.toolEventCount(), 1);
      final rows = dao.recentToolEvents();
      expect(rows.single['tool'], 'network_list');
      expect(rows.single['arg_keys'], '["hostContains","statusMin"]');
      expect(rows.single['result_bytes'], 1840);
    });

    test('toolEventCounts groups by (tool, outcome)', () {
      void ev(String tool, String outcome) => dao.insertToolEvent(
            tsMs: 1000,
            correlationId: 'c',
            tool: tool,
            outcome: outcome,
          );
      ev('network_list', 'ok');
      ev('network_list', 'ok');
      ev('network_list', 'empty');
      ev('logs_tail', 'error');

      final counts = dao.toolEventCounts();
      int countFor(String tool, String outcome) => counts
          .firstWhere((r) => r['tool'] == tool && r['outcome'] == outcome)['count'] as int;
      expect(countFor('network_list', 'ok'), 2);
      expect(countFor('network_list', 'empty'), 1);
      expect(countFor('logs_tail', 'error'), 1);
    });

    test('since filter excludes older events', () {
      dao.insertToolEvent(
          tsMs: 1000, correlationId: 'c', tool: 'old', outcome: 'ok');
      dao.insertToolEvent(
          tsMs: 9000, correlationId: 'c', tool: 'new', outcome: 'ok');
      final recent = dao.recentToolEvents(sinceMs: 5000);
      expect(recent.map((r) => r['tool']), ['new']);
      final counts = dao.toolEventCounts(sinceMs: 5000);
      expect(counts.every((r) => r['tool'] == 'new'), isTrue);
    });

    test('recentToolEvents is newest-first and respects limit', () {
      for (var i = 0; i < 5; i++) {
        dao.insertToolEvent(
            tsMs: 1000 + i, correlationId: 'c', tool: 't$i', outcome: 'ok');
      }
      final rows = dao.recentToolEvents(limit: 2);
      expect(rows.map((r) => r['tool']), ['t4', 't3']);
    });

    test('toolEventsAfterId returns only newer rows, carrying id + ts_ms', () {
      for (var i = 0; i < 4; i++) {
        dao.insertToolEvent(
            tsMs: 1000 + i, correlationId: 'c', tool: 't$i', outcome: 'ok');
      }
      // ids are 1..4. After id=2 -> ids 3,4.
      final rows = dao.toolEventsAfterId(afterId: 2);
      expect(rows.map((r) => r['id']), [3, 4]);
      expect(rows.first.containsKey('ts_ms'), isTrue);
      expect(rows.first.containsKey('correlation_id'), isTrue);
      // afterId past the end -> empty.
      expect(dao.toolEventsAfterId(afterId: 99), isEmpty);
      // afterId 0 -> everything.
      expect(dao.toolEventsAfterId(afterId: 0).length, 4);
    });
  });
}
