import 'dart:io';

import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:test/test.dart';

/// #18: log<->network correlation. logsNear / httpRequestsNear back the
/// correlate_at tool: window filtering + nearest-first ordering + optional
/// isolate scoping.
void main() {
  group('logsNear / httpRequestsNear', () {
    late Directory dir;
    late CapturesDao dao;
    late int sid;
    const anchor = 10000; // ms

    setUp(() {
      dir = Directory.systemTemp.createTempSync('correlate_near_test_');
      CapturesDatabase.open(dataDir: dir.path);
      dao = CapturesDao();
      sid = dao.createSession(
        appName: 'app',
        vmServiceUri: 'ws://x',
        isolateId: null,
        projectPath: null,
      );
      void log(int tsMs, String msg, {String? iso}) {
        CapturesDatabase.instance.raw.execute(
          'INSERT INTO log_records(session_id, isolate_id, timestamp_ms, source, message) '
          'VALUES (?,?,?,?,?)',
          [sid, iso, tsMs, 'logging', msg],
        );
      }

      void req(String id, int startMs, {String? iso}) {
        CapturesDatabase.instance.raw.execute(
          'INSERT INTO http_requests(session_id, vm_id, isolate_id, method, url, start_us) '
          'VALUES (?,?,?,?,?,?)',
          [sid, id, iso, 'GET', 'https://x/$id', startMs * 1000],
        );
      }

      log(anchor - 500, 'near-before');
      log(anchor + 100, 'nearest');
      log(anchor + 5000, 'far'); // outside a 1000ms window
      log(anchor + 50, 'other-isolate', iso: 'isolates/2');

      req('r-before', anchor - 200);
      req('r-after', anchor + 300);
      req('r-far', anchor + 9000); // outside
    });

    tearDown(() {
      CapturesDatabase.instance.close();
      dir.deleteSync(recursive: true);
    });

    test('logsNear filters to the window, nearest first', () {
      final logs = dao.logsNear(sessionId: sid, anchorMs: anchor, windowMs: 1000);
      final msgs = logs.map((r) => r['message']).toList();
      expect(msgs, isNot(contains('far')), reason: '5000ms out is excluded');
      // nearest first: +50 (other-isolate), +100, -500
      expect(msgs.first, 'other-isolate');
      expect(msgs, contains('nearest'));
      expect(msgs, contains('near-before'));
    });

    test('logsNear respects the isolate filter', () {
      final logs = dao.logsNear(
        sessionId: sid,
        anchorMs: anchor,
        windowMs: 1000,
        isolateId: 'isolates/2',
      );
      expect(logs.map((r) => r['message']), ['other-isolate']);
    });

    test('httpRequestsNear filters to the window, nearest first', () {
      final reqs =
          dao.httpRequestsNear(sessionId: sid, anchorMs: anchor, windowMs: 1000);
      final ids = reqs.map((r) => r['vm_id']).toList();
      expect(ids, isNot(contains('r-far')));
      // |−200| < |+300| → r-before first
      expect(ids, ['r-before', 'r-after']);
    });

    test('limit caps each side', () {
      final logs = dao.logsNear(
          sessionId: sid, anchorMs: anchor, windowMs: 10000, limit: 1);
      expect(logs, hasLength(1));
      expect(logs.first['message'], 'other-isolate', reason: 'nearest kept');
    });
  });
}
