import 'dart:io';

import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:test/test.dart';

/// #15: history-path `messageContains` filter on persisted log_records (the
/// path used after session_open). Mirrors the live LogBuffer.tail filter.
void main() {
  group('queryLogs messageContains', () {
    late Directory dir;
    late CapturesDao dao;
    late int sid;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('query_logs_test_');
      CapturesDatabase.open(dataDir: dir.path);
      dao = CapturesDao();
      sid = dao.createSession(
        appName: 'app',
        vmServiceUri: 'ws://x',
        isolateId: null,
        projectPath: null,
      );
      for (final m in const [
        '[EventTracker] aeon_transaction_started',
        '[KycTier] upgraded',
        'unrelated chatter',
      ]) {
        CapturesDatabase.instance.raw.execute(
          'INSERT INTO log_records(session_id, source, level, logger, message) '
          'VALUES (?,?,?,?,?)',
          [sid, 'logging', null, '', m],
        );
      }
    });

    tearDown(() {
      CapturesDatabase.instance.close();
      dir.deleteSync(recursive: true);
    });

    test('case-insensitive substring on message body', () {
      final rows = dao.queryLogs(sessionId: sid, messageContains: 'eventtracker');
      expect(rows, hasLength(1));
      expect(rows.single['message'], contains('EventTracker'));
    });

    test('no match returns empty', () {
      expect(dao.queryLogs(sessionId: sid, messageContains: 'nope'), isEmpty);
    });

    test('omitted filter returns everything', () {
      expect(dao.queryLogs(sessionId: sid), hasLength(3));
    });
  });
}
