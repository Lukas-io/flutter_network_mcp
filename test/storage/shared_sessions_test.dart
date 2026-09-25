import 'dart:io';
import 'dart:isolate';

import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/storage/schema.dart' show currentVersion;
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:test/test.dart';

import '../support/schema_rollback.dart';

Set<String> _schemaObjects() => {
      for (final r in CapturesDatabase.instance.raw.select(
          "SELECT type, name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'"))
        '${r['type']}:${r['name']}',
    };

bool _ended(int id) =>
    CapturesDatabase.instance.raw
        .select('SELECT ended_at FROM sessions WHERE id=?', [id])
        .first['ended_at'] !=
    null;

/// #97 follow-up: several server processes share one session row.
void main() {
  late Directory dir;
  late CapturesDao dao;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('shared_sessions_test_');
    CapturesDatabase.open(dataDir: dir.path);
    dao = CapturesDao();
  });
  tearDown(() {
    CapturesDatabase.instance.close();
    dir.deleteSync(recursive: true);
  });

  int session(String uri) => dao.createSession(
      appName: 'app', vmServiceUri: uri, isolateId: null, projectPath: null);

  group('migration v12 -> v13', () {
    test('a DB created fresh at v12 gains the live-URI index and matches a fresh v13 schema', () {
      final fresh = _schemaObjects();
      final raw = CapturesDatabase.instance.raw;
      rollBackV13(raw);
      raw.execute('DROP INDEX idx_sessions_live_uri');
      raw.execute("UPDATE _meta SET value='12' WHERE key='schema_version'");
      for (var i = 0; i < 2; i++) {
        raw.execute("INSERT INTO sessions(started_at, vm_service_uri) VALUES (1, 'ws://dup')");
      }
      CapturesDatabase.instance.close();

      CapturesDatabase.open(dataDir: dir.path);
      expect(_schemaObjects(), fresh);
      final open = CapturesDatabase.instance.raw
          .select("SELECT COUNT(*) AS n FROM sessions WHERE vm_service_uri='ws://dup' AND ended_at IS NULL")
          .first['n'];
      expect(open, 1);
    });
  });

  group('a session shared by two processes', () {
    late Process other;
    setUp(() async => other = await Process.start('sleep', ['30']));
    tearDown(() => other.kill());

    test('stays open until its last live process leaves', () async {
      final sid = session('ws://a');
      dao.attachProcess(sid);
      dao.attachProcess(sid, pid: other.pid);

      expect(dao.leaveSession(sid), isFalse);
      expect(_ended(sid), isFalse);

      other.kill();
      await other.exitCode;
      dao.attachProcess(sid);
      expect(dao.leaveSession(sid), isTrue, reason: 'the other pid is gone');
      expect(_ended(sid), isTrue);
    });

    test('a pid now held by a process that started after the attach is treated as gone', () {
      final sid = session('ws://reused');
      final hourAgo = DateTime.now().millisecondsSinceEpoch - 3600 * 1000;
      CapturesDatabase.instance.raw.execute(
        'INSERT INTO session_attachments(session_id, pid, attached_at) VALUES (?,?,?)',
        [sid, other.pid, hourAgo],
      );
      expect(dao.otherAttachedProcesses(sid), 0);
    });

    test('keep:true releases this process without ending the row', () {
      final sid = session('ws://kept');
      dao.attachProcess(sid);
      dao.releaseAttachment(sid);
      final held = CapturesDatabase.instance.raw.select(
          'SELECT COUNT(*) AS n FROM session_attachments WHERE session_id=?',
          [sid]).first['n'];
      expect(held, 0);
      expect(_ended(sid), isFalse);
    });

    test('the startup sweep spares it but ends rows whose processes are gone', () {
      final shared = session('ws://shared');
      dao.attachProcess(shared, pid: other.pid);
      final crashed = session('ws://crashed');
      dao.attachProcess(crashed, pid: 999999);
      final unowned = session('ws://legacy');

      expect(dao.endOrphanedSessions(), 2);
      expect(_ended(shared), isFalse);
      expect(_ended(crashed), isTrue);
      expect(_ended(unowned), isTrue);
    });
  });

  test('repointing onto a URI another process already opened adopts that row', () {
    final mine = session('ws://old');
    dao.attachProcess(mine);
    final theirs = session('ws://new');

    final id = dao.repointSession(mine, vmServiceUri: 'ws://new', isolateId: null);
    expect(id, theirs);
    expect(_ended(mine), isTrue);
  });

  test('a log record with the same dedup key is stored once', () {
    final sid = session('ws://logs');
    int? insert(String? key) => dao.insertLog(
        sessionId: sid, timestampMs: 1, source: 'logging', message: 'm', dedupKey: key);

    expect(insert('logging:iso:7:1'), isNotNull);
    expect(insert('logging:iso:7:1'), isNull);
    expect(insert(null), isNotNull);
    expect(insert(null), isNotNull);
    final n = CapturesDatabase.instance.raw
        .select('SELECT COUNT(*) AS n FROM log_records WHERE session_id=?', [sid])
        .first['n'];
    expect(n, 3);
  });

  test('a second server opening the DB while another holds its lock waits instead of failing', () async {
    final other = Directory.systemTemp.createTempSync('shared_open_test_');
    addTearDown(() => other.deleteSync(recursive: true));
    final path = '${other.path}/captures.db';
    final locked = ReceivePort();
    final signal = locked.sendPort;
    final holder = Isolate.run(() {
      // A brand-new file, still in rollback-journal mode: switching it to WAL needs the lock this holds.
      final db = sql.sqlite3.open(path);
      db.execute('BEGIN IMMEDIATE');
      db.execute('CREATE TABLE IF NOT EXISTS _meta (key TEXT PRIMARY KEY, value TEXT)');
      signal.send(true);
      sleep(const Duration(seconds: 1));
      db.execute('COMMIT');
      db.dispose();
    });
    await locked.first;
    CapturesDatabase.instance.close();
    CapturesDatabase.open(dataDir: other.path);
    await holder;
    final version = CapturesDatabase.instance.raw
        .select("SELECT value FROM _meta WHERE key='schema_version'")
        .first['value'];
    expect(version, '${currentVersion}');
  });

  test('parseElapsed reads every ps etime shape', () {
    expect(parseElapsed('00:07'), const Duration(seconds: 7));
    expect(parseElapsed('01:02:03'), const Duration(hours: 1, minutes: 2, seconds: 3));
    expect(parseElapsed('2-01:00:00'), const Duration(days: 2, hours: 1));
    expect(parseElapsed('soon'), isNull);
  });
}
