import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_network_mcp/src/config/db_cap_config.dart';
import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:test/test.dart';

/// #58: rolling DB size cap — config parsing + oldest-first eviction primitives
/// that never touch the protected (currently-attached) sessions.
void main() {
  group('DbCapConfig parsing', () {
    test('unset / blank -> 2 GB default', () {
      expect(DbCapConfig.readForTest(null), DbCapConfig.defaultMaxBytes);
      expect(DbCapConfig.readForTest('   '), DbCapConfig.defaultMaxBytes);
    });

    test('off switches disable the cap', () {
      for (final off in ['0', 'off', 'false', 'disabled', 'no', 'OFF']) {
        expect(DbCapConfig.readForTest(off), isNull, reason: off);
      }
    });

    test('explicit byte count is honored', () {
      expect(DbCapConfig.readForTest('524288000'), 524288000);
    });

    test('garbage falls back to default', () {
      expect(DbCapConfig.readForTest('banana'), DbCapConfig.defaultMaxBytes);
      expect(DbCapConfig.readForTest('-5'), DbCapConfig.defaultMaxBytes);
    });

    test('below the 1 MB floor is raised to the floor', () {
      expect(DbCapConfig.readForTest('1000'), 1024 * 1024);
    });
  });

  group('eviction primitives', () {
    late Directory dir;
    late CapturesDao dao;
    late int oldSid;
    late int liveSid;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('db_cap_test_');
      CapturesDatabase.open(dataDir: dir.path);
      dao = CapturesDao();
      oldSid = dao.createSession(
          appName: 'old', vmServiceUri: 'ws://old', isolateId: null, projectPath: null);
      liveSid = dao.createSession(
          appName: 'live', vmServiceUri: 'ws://live', isolateId: null, projectPath: null);
    });

    tearDown(() {
      CapturesDatabase.instance.close();
      dir.deleteSync(recursive: true);
    });

    void insertReq(int sid, String vmId, int startUs) {
      CapturesDatabase.instance.raw.execute(
        'INSERT INTO http_requests(session_id, vm_id, start_us, bodies_fetched) '
        'VALUES (?,?,?,1)',
        [sid, vmId, startUs],
      );
    }

    void insertBody(int sid, String vmId, int size) {
      CapturesDatabase.instance.raw.execute(
        'INSERT INTO http_bodies(session_id, vm_id, which, bytes, size) '
        'VALUES (?,?,?,?,?)',
        [sid, vmId, 'response', Uint8List(size), size],
      );
    }

    void insertLog(int sid, int tsMs) {
      CapturesDatabase.instance.raw.execute(
        'INSERT INTO log_records(session_id, timestamp_ms, source, level, message) '
        'VALUES (?,?,?,?,?)',
        [sid, tsMs, 'test', 'INFO', 'm'],
      );
    }

    test('evictOldestBodies drops oldest-first up to the byte target', () {
      insertReq(oldSid, 'a', 100);
      insertReq(oldSid, 'b', 200);
      insertReq(oldSid, 'c', 300);
      insertBody(oldSid, 'a', 1000);
      insertBody(oldSid, 'b', 1000);
      insertBody(oldSid, 'c', 1000);

      final r = dao.evictOldestBodies(targetBytes: 1500);
      // Needs 1500 bytes -> drops 'a' (1000) then 'b' (1000) = 2000 >= 1500.
      expect(r.dropped, 2);
      expect(r.bytesFreed, 2000);
      final remaining = CapturesDatabase.instance.raw
          .select('SELECT vm_id FROM http_bodies ORDER BY vm_id');
      expect(remaining.map((row) => row['vm_id']), ['c']);
      // metadata rows stay; their bodies_fetched is cleared
      final fetched = CapturesDatabase.instance.raw
          .select("SELECT bodies_fetched FROM http_requests WHERE vm_id='a'")
          .first['bodies_fetched'];
      expect(fetched, 0);
    });

    test('evictOldestBodies never touches a protected session', () {
      insertReq(oldSid, 'old1', 100);
      insertReq(liveSid, 'live1', 50); // older, but protected
      insertBody(oldSid, 'old1', 1000);
      insertBody(liveSid, 'live1', 1000);

      final r = dao.evictOldestBodies(targetBytes: 100000, protectedSessionIds: {liveSid});
      expect(r.dropped, 1); // only the old session's body
      final live = CapturesDatabase.instance.raw
          .select('SELECT COUNT(*) AS n FROM http_bodies WHERE session_id=?', [liveSid])
          .first['n'];
      expect(live, 1); // live body retained
    });

    test('evictOldestLogs drops oldest-first, skipping protected sessions', () {
      insertLog(oldSid, 100);
      insertLog(oldSid, 200);
      insertLog(liveSid, 50); // oldest, but protected
      final dropped = dao.evictOldestLogs(maxRows: 10, protectedSessionIds: {liveSid});
      expect(dropped, 2);
      final liveLogs = CapturesDatabase.instance.raw
          .select('SELECT COUNT(*) AS n FROM log_records WHERE session_id=?', [liveSid])
          .first['n'];
      expect(liveLogs, 1);
    });

    test('sessionIdsOldestFirst excludes protected, orders by age', () {
      expect(dao.sessionIdsOldestFirst(protectedSessionIds: {liveSid}), [oldSid]);
      expect(dao.sessionIdsOldestFirst().toSet(), {oldSid, liveSid});
    });

    test('oldestRetainedRequestMs reflects the min start_us', () {
      insertReq(oldSid, 'a', 5000000); // 5000000 us = 5000 ms
      insertReq(oldSid, 'b', 9000000);
      expect(dao.oldestRetainedRequestMs(), 5000);
    });
  });
}
