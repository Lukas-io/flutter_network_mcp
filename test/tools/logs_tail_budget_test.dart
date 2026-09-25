import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:flutter_network_mcp/src/config/session_filters.dart';
import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/tools/logs_tail.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late int sid;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('logs_budget_test_');
    CapturesDatabase.open(dataDir: dir.path);
    sid = CapturesDao().createSession(
        appName: 'a', vmServiceUri: 'ws://x', isolateId: null, projectPath: null);
    for (var i = 0; i < 20; i++) {
      CapturesDatabase.instance.raw.execute(
        'INSERT INTO log_records(session_id, timestamp_ms, source, level, message) '
        'VALUES (?,?,?,?,?)',
        [sid, 1000 + i, 'logging', 800, 'record $i ${'x' * 200}'],
      );
    }
  });

  tearDown(() {
    SessionFilters.instance.clear();
    CapturesDatabase.instance.close();
    dir.deleteSync(recursive: true);
  });

  Future<Map<String, Object?>> tail([Map<String, Object?> extra = const {}]) async {
    final r = await logsTail(CallToolRequest(
        name: 'logs_tail', arguments: {'sessionId': sid, ...extra}));
    return r.structuredContent!;
  }

  test('maxTokens keeps the newest records and reports what it dropped',
      () async {
    final sc = await tail({'maxTokens': 200});
    final entries = sc['entries'] as List;
    final budget = sc['budget'] as Map;
    expect(entries.length, lessThan(20));
    expect(budget['dropped'], 20 - entries.length);
    expect((entries.first as Map)['message'], startsWith('record 19'));
    expect(sc['nextCursor'], (entries.first as Map)['id']);
    expect((sc['warnings'] as List).join(), contains('token budget'));
  });

  test('session_configure maxResponseTokens is the default budget', () async {
    SessionFilters.instance.maxResponseTokens = 200;
    final sc = await tail();
    expect((sc['budget'] as Map)['dropped'], greaterThan(0));
  });

  test('no budget returns everything and no budget block', () async {
    final sc = await tail();
    expect(sc['entries'], hasLength(20));
    expect(sc.containsKey('budget'), isFalse);
  });
}
