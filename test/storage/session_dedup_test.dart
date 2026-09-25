import 'dart:io';

import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:test/test.dart';

import '../support/schema_rollback.dart';

/// #97: one open session row per live VM URI. Several server processes attaching
/// to the same app used to each blind-insert a row, inflating sessionCount and
/// giving no signal which duplicate to query.
void main() {
  group('createSession dedup (v12 index)', () {
    late Directory dir;
    late CapturesDao dao;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('session_dedup_test_');
      CapturesDatabase.open(dataDir: dir.path);
      dao = CapturesDao();
    });
    tearDown(() {
      CapturesDatabase.instance.close();
      dir.deleteSync(recursive: true);
    });

    test('two attaches to the same open URI reuse one row', () {
      final a = dao.createSession(
          appName: 'app', vmServiceUri: 'ws://x', isolateId: 'i1', projectPath: '/a');
      final b = dao.createSession(
          appName: 'app', vmServiceUri: 'ws://x', isolateId: 'i2', projectPath: '/b');
      expect(a, b);
      final n = CapturesDatabase.instance.raw
          .select("SELECT COUNT(*) AS n FROM sessions WHERE vm_service_uri='ws://x'")
          .first['n'] as int;
      expect(n, 1);
    });

    test('null URIs stay distinct (nothing to dedupe on)', () {
      final a = dao.createSession(
          appName: 'app', vmServiceUri: null, isolateId: null, projectPath: null);
      final b = dao.createSession(
          appName: 'app', vmServiceUri: null, isolateId: null, projectPath: null);
      expect(a, isNot(b));
    });

    test('an ended row does not block a fresh open row for the same URI', () {
      final a = dao.createSession(
          appName: 'app', vmServiceUri: 'ws://y', isolateId: null, projectPath: null);
      dao.endSession(a);
      final b = dao.createSession(
          appName: 'app', vmServiceUri: 'ws://y', isolateId: null, projectPath: null);
      expect(b, isNot(a));
    });
  });

  group('migration v11 -> v12 collapses existing duplicates', () {
    test('duplicate open rows are deduped and the index is built', () {
      final dir = Directory.systemTemp.createTempSync('session_migrate_test_');
      addTearDown(() => dir.deleteSync(recursive: true));

      // Open (fresh -> v12), then roll back to a v11-shaped DB: drop the index
      // and seed duplicate open rows the way pre-fix processes did.
      CapturesDatabase.open(dataDir: dir.path);
      final raw = CapturesDatabase.instance.raw;
      raw.execute('DROP INDEX IF EXISTS idx_sessions_live_uri');
      rollBackV13(raw);
      raw.execute("UPDATE _meta SET value='11' WHERE key='schema_version'");
      for (var i = 0; i < 4; i++) {
        raw.execute(
          'INSERT INTO sessions(started_at, app_name, vm_service_uri, project_path) '
          "VALUES (100, 'app', 'ws://dup', ?)",
          ['/cwd$i'],
        );
      }
      CapturesDatabase.instance.close();

      // Reopen -> migrate 11 to 12.
      CapturesDatabase.open(dataDir: dir.path);
      addTearDown(() => CapturesDatabase.instance.close());
      final r2 = CapturesDatabase.instance.raw;
      final open = r2
          .select("SELECT COUNT(*) AS n FROM sessions "
              "WHERE vm_service_uri='ws://dup' AND ended_at IS NULL")
          .first['n'] as int;
      expect(open, 1, reason: 'only one open row survives per URI');
      final deduped = r2
          .select("SELECT COUNT(*) AS n FROM sessions "
              "WHERE vm_service_uri='ws://dup' AND note LIKE '%[deduped]%'")
          .first['n'] as int;
      expect(deduped, 3, reason: 'the other three are closed and tagged');
      // The unique index now rejects a second open row for the URI.
      expect(
        () => r2.execute(
            "INSERT INTO sessions(started_at, vm_service_uri) VALUES (1, 'ws://dup')"),
        throwsA(anything),
      );
    });
  });
}
