import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:flutter_network_mcp/src/storage/capture_writer.dart';
import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/tools/body_fetch.dart';
import 'package:flutter_network_mcp/src/util/scope.dart';
import 'package:test/test.dart';

/// #95/#96/#100: bodies stranded when a session ends, plus the honesty of the
/// messages that report the gap.
void main() {
  late Directory dir;
  late CapturesDao dao;
  late int sid;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('body_flush_test_');
    CapturesDatabase.open(dataDir: dir.path);
    dao = CapturesDao();
    sid = dao.createSession(
      appName: 'app', vmServiceUri: 'ws://x', isolateId: null, projectPath: null,
    );
  });
  tearDown(() {
    CapturesDatabase.instance.close();
    dir.deleteSync(recursive: true);
  });

  void insertReq(String vmId, {int fetched = 0}) {
    CapturesDatabase.instance.raw.execute(
      'INSERT INTO http_requests(session_id, vm_id, start_us, end_us, '
      'body_fetch_attempts, bodies_fetched) VALUES (?,?,?,?,?,?)',
      [sid, vmId, 100, 200, 0, fetched],
    );
  }

  group('countUnpersistedBodies (#100)', () {
    test('counts only rows with no stored body', () {
      insertReq('a');
      insertReq('b');
      insertReq('c', fetched: 1);
      expect(dao.countUnpersistedBodies(sid), 2);
    });

    test('zero when every body is fetched', () {
      insertReq('a', fetched: 1);
      expect(dao.countUnpersistedBodies(sid), 0);
    });
  });

  group('noBodyResult wording (#96)', () {
    Map<String, Object?> structured(CallToolResult r) =>
        r.structuredContent!;

    test('a live session is told to retry', () {
      insertReq('r1');
      final scope = Scope(sessionId: sid, appName: 'app', isLive: true);
      final s = structured(
          noBodyResult(scope, 'r1', 'response', 'live-db-fallback', null));
      final warnings = (s['warnings'] as List).cast<String>().join(' ');
      expect(warnings, contains('Retry'));
      expect(warnings, isNot(contains('unrecoverable')));
    });

    test('an ended session is told the bytes are unrecoverable', () {
      insertReq('r1');
      final scope = Scope(sessionId: sid, appName: 'app', isLive: false);
      final s = structured(
          noBodyResult(scope, 'r1', 'response', 'history', null));
      final warnings = (s['warnings'] as List).cast<String>().join(' ');
      expect(warnings, contains('unrecoverable'));
      expect(warnings, isNot(contains('Retry in')));
    });
  });

  group('flushPendingBodies guard', () {
    test('is a no-op with no VM attached and does not throw', () async {
      final writer = CaptureWriter();
      await writer.flushPendingBodies();
      await writer.stop(flush: true);
    });
  });
}
