import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/tools/network_query.dart';
import 'package:test/test.dart';

/// End-to-end: a bad network_query must self-correct by returning the schema
/// inline + errorKind:bad_query, so the agent fixes its SQL on the next call
/// instead of looping (telemetry showed a query->query self-loop + errors).
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nq_selfcorrect_');
    CapturesDatabase.open(dataDir: dir.path);
  });
  tearDown(() {
    CapturesDatabase.instance.close();
    dir.deleteSync(recursive: true);
  });

  test('bad column name -> errorKind:bad_query + inline schema', () async {
    final res = await networkQuery(CallToolRequest(
      name: 'network_query',
      arguments: {'sql': 'SELECT nonexistent_col FROM http_requests'},
    ));
    expect(res.isError, isTrue);
    final sc = res.structuredContent!;
    expect(sc['errorKind'], 'bad_query');
    final schema = sc['schema'] as Map<String, Object?>;
    expect(schema.keys, contains('http_requests'));
    expect((schema['http_requests'] as List), contains('host'));
  });

  test('valid SELECT still succeeds (no regression)', () async {
    final res = await networkQuery(CallToolRequest(
      name: 'network_query',
      arguments: {'sql': 'SELECT COUNT(*) AS n FROM sessions'},
    ));
    expect(res.isError, isFalse);
    expect(res.structuredContent!['rowCount'], 1);
  });

  test('non-SELECT is rejected with bad_query, not executed', () async {
    final res = await networkQuery(CallToolRequest(
      name: 'network_query',
      arguments: {'sql': 'DELETE FROM sessions'},
    ));
    expect(res.isError, isTrue);
    expect(res.structuredContent!['errorKind'], 'bad_query');
  });
}
