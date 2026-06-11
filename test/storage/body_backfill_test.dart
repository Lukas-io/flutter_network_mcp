import 'dart:io';

import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:test/test.dart';

/// Issue #13: response bodies for chunked / gzip responses were stranded
/// because the dart:io profiler never set `end_us`, and the old backfill gate
/// required `end_us IS NOT NULL`. These tests pin the relaxed gate + the
/// attempt cap that replaced it (schema v6).
void main() {
  group('pendingBodyFetches gate', () {
    late Directory dir;
    late CapturesDao dao;
    late int sid;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('body_backfill_test_');
      CapturesDatabase.open(dataDir: dir.path);
      dao = CapturesDao();
      sid = dao.createSession(
        appName: 'app',
        vmServiceUri: 'ws://x',
        isolateId: null,
        projectPath: null,
      );
    });

    tearDown(() {
      CapturesDatabase.instance.close();
      dir.deleteSync(recursive: true);
    });

    void insertReq(
      String vmId, {
      int? startUs,
      int? endUs,
      int attempts = 0,
      int fetched = 0,
    }) {
      CapturesDatabase.instance.raw.execute(
        'INSERT INTO http_requests(session_id, vm_id, start_us, end_us, '
        'body_fetch_attempts, bodies_fetched) VALUES (?,?,?,?,?,?)',
        [sid, vmId, startUs, endUs, attempts, fetched],
      );
    }

    test('complete request is always eligible and flagged isComplete', () {
      insertReq('a', startUs: 100, endUs: 200);
      final pending = dao.pendingBodyFetches(sid, staleBeforeUs: 1000000);
      expect(pending, hasLength(1));
      expect(pending.single.vmId, 'a');
      expect(pending.single.isComplete, isTrue);
    });

    test('response-incomplete but stale request becomes eligible', () {
      insertReq('a', startUs: 500000, endUs: null); // older than staleBefore
      final pending = dao.pendingBodyFetches(sid, staleBeforeUs: 1000000);
      expect(pending, hasLength(1));
      expect(pending.single.vmId, 'a');
      expect(pending.single.isComplete, isFalse,
          reason: 'no end_us → response not complete');
    });

    test('response-incomplete and recent request is NOT eligible yet', () {
      insertReq('a', startUs: 2000000, endUs: null); // newer than staleBefore
      final pending = dao.pendingBodyFetches(sid, staleBeforeUs: 1000000);
      expect(pending, isEmpty,
          reason: 'within the grace window; give the profiler time');
    });

    test('incomplete request past the attempt cap is dropped', () {
      insertReq('a', startUs: 500000, endUs: null, attempts: 3);
      final pending =
          dao.pendingBodyFetches(sid, staleBeforeUs: 1000000, maxAttempts: 3);
      expect(pending, isEmpty,
          reason: 'attempts >= maxAttempts stops re-polling body-less rows');
    });

    test('staleBeforeUs null restores legacy complete-only behaviour', () {
      insertReq('complete', startUs: 100, endUs: 200);
      insertReq('incomplete', startUs: 100, endUs: null);
      final pending = dao.pendingBodyFetches(sid); // no staleBeforeUs
      expect(pending.map((e) => e.vmId), ['complete']);
    });

    test('already-fetched rows never re-appear', () {
      insertReq('a', startUs: 100, endUs: 200, fetched: 1);
      insertReq('b', startUs: 500000, endUs: null, fetched: 1);
      final pending = dao.pendingBodyFetches(sid, staleBeforeUs: 1000000);
      expect(pending, isEmpty);
    });

    test('complete rows sort ahead of incomplete rows', () {
      insertReq('incomplete', startUs: 100, endUs: null);
      insertReq('complete', startUs: 300, endUs: 400);
      final pending = dao.pendingBodyFetches(sid, staleBeforeUs: 1000000);
      expect(pending.map((e) => e.vmId), ['complete', 'incomplete']);
    });
  });

  group('backfill attempt helpers', () {
    late Directory dir;
    late CapturesDao dao;
    late int sid;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('body_backfill_helpers_');
      CapturesDatabase.open(dataDir: dir.path);
      dao = CapturesDao();
      sid = dao.createSession(
        appName: 'app',
        vmServiceUri: 'ws://x',
        isolateId: null,
        projectPath: null,
      );
      CapturesDatabase.instance.raw.execute(
        'INSERT INTO http_requests(session_id, vm_id, start_us, end_us) '
        'VALUES (?,?,?,?)',
        [sid, 'a', 500000, null],
      );
    });

    tearDown(() {
      CapturesDatabase.instance.close();
      dir.deleteSync(recursive: true);
    });

    test('bumpBodyFetchAttempt eventually drops the row from the queue', () {
      for (var i = 0; i < 3; i++) {
        expect(
          dao.pendingBodyFetches(sid, staleBeforeUs: 1000000, maxAttempts: 3),
          hasLength(1),
          reason: 'attempt $i still under the cap',
        );
        dao.bumpBodyFetchAttempt(sid, 'a');
      }
      expect(
        dao.pendingBodyFetches(sid, staleBeforeUs: 1000000, maxAttempts: 3),
        isEmpty,
        reason: '3 attempts reaches the cap',
      );
    });

    test('markBodiesFetched removes the row immediately', () {
      dao.markBodiesFetched(sid, 'a');
      expect(
        dao.pendingBodyFetches(sid, staleBeforeUs: 1000000),
        isEmpty,
      );
    });
  });
}
