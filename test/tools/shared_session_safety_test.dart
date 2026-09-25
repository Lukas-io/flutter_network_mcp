import 'dart:io';
import 'dart:typed_data';

import 'package:dart_mcp/server.dart';
import 'package:flutter_network_mcp/src/state/log_buffer.dart';
import 'package:flutter_network_mcp/src/state/session.dart';
import 'package:flutter_network_mcp/src/storage/capture_writer.dart';
import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/storage/db_cap.dart';
import 'package:flutter_network_mcp/src/tools/session_delete.dart';
import 'package:flutter_network_mcp/src/tools/session_list.dart';
import 'package:flutter_network_mcp/src/tools/session_open.dart';
import 'package:flutter_network_mcp/src/util/guidance.dart';
import 'package:flutter_network_mcp/src/vm/log_stream.dart';
import 'package:flutter_network_mcp/src/vm/vm_client.dart';
import 'package:test/test.dart';

/// A session still capturing, in this process or in another server process on the same DB, is never deleted, evicted or shown as interrupted.
void main() {
  late Directory dir;
  late CapturesDao dao;
  late Process other;

  AttachedSession fakeSession(int id, String uri) => AttachedSession(
        id: id,
        appName: 'app$id',
        vmServiceUri: uri,
        vm: VmClient(),
        captureWriter: CaptureWriter(),
        logBuffer: LogBuffer(),
        logStream: LogStreamSubscriber(),
        attachedAt: DateTime.now(),
        httpProfilingEnabled: true,
        socketProfilingEnabled: true,
      );

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('shared_safety_test_');
    CapturesDatabase.open(dataDir: dir.path);
    dao = CapturesDao();
    other = await Process.start('sleep', ['30']);
  });
  tearDown(() async {
    other.kill();
    Session.instance.viewedSessionId = null;
    await SessionRegistry.instance.detachAll();
    CapturesDatabase.instance.close();
    dir.deleteSync(recursive: true);
  });

  int session(String uri) => dao.createSession(
      appName: 'app', vmServiceUri: uri, isolateId: null, projectPath: null);

  int sharedWithOtherProcess() {
    final id = session('ws://shared');
    dao.attachProcess(id, pid: other.pid);
    return id;
  }

  Future<CallToolResult> delete(int id) => Future.value(sessionDelete(
      CallToolRequest(name: 'session_delete', arguments: {'id': id, 'confirm': true})));

  group('session_delete', () {
    test('refuses one of several sessions attached here', () async {
      final a = session('ws://a');
      final b = session('ws://b');
      SessionRegistry.instance.register(fakeSession(a, 'ws://a'));
      SessionRegistry.instance.register(fakeSession(b, 'ws://b'));

      final r = await delete(b);
      expect(r.isError, isTrue);
      expect(r.structuredContent!['errorKind'], 'session_in_use');
      expect(dao.getSession(b), isNotNull);
    });

    test('refuses a session another server process captures into', () async {
      final id = sharedWithOtherProcess();
      final r = await delete(id);
      expect(r.isError, isTrue);
      expect(r.structuredContent!['errorKind'], 'session_in_use');
      expect(r.structuredContent!['otherProcesses'], 1);
      expect(dao.getSession(id), isNotNull);
    });

    test('deletes it once the other process is gone', () async {
      final id = sharedWithOtherProcess();
      other.kill();
      await other.exitCode;
      final r = await delete(id);
      expect(r.isError, isFalse);
      expect(dao.getSession(id), isNull);
    });
  });

  group('a session another process captures into reads as live', () {
    test('in session_list', () async {
      final id = sharedWithOtherProcess();
      final orphan = session('ws://orphan');
      final res = await sessionList(CallToolRequest(name: 'session_list'));
      final rows = {
        for (final s in (res.structuredContent!['sessions'] as List).cast<Map<String, Object?>>())
          s['id']: s,
      };
      expect(rows[id]!['status'], 'live');
      expect(rows[id]!['capturedElsewhere'], isTrue);
      expect(rows[orphan]!['status'], 'interrupted');
      expect(rows[orphan]!.containsKey('capturedElsewhere'), isFalse);
    });

    test('in session_open and SessionStateView', () async {
      final id = sharedWithOtherProcess();
      final res = await sessionOpen(
          CallToolRequest(name: 'session_open', arguments: {'id': id}));
      expect(res.structuredContent!['summary'], contains('captured by another server process'));
      expect(res.structuredContent!['capturedElsewhere'], isTrue);

      final state = SessionStateView.of(id);
      expect(state.isInterrupted, isFalse);
      expect(state.capturedElsewhere, isTrue);
      expect(emptyCaptureHint(state, reRun: 'network_list'), contains('another server process'));
    });
  });

  test('the DB cap sweep never evicts a session another process captures into', () {
    final shared = sharedWithOtherProcess();
    final done = session('ws://done');
    dao.endSession(done);
    final raw = CapturesDatabase.instance.raw;
    for (final sid in [shared, done]) {
      raw.execute(
        'INSERT INTO http_requests(session_id, vm_id, start_us, bodies_fetched) VALUES (?,?,?,1)',
        [sid, 'r$sid', sid],
      );
      raw.execute(
        'INSERT INTO http_bodies(session_id, vm_id, which, bytes, size) VALUES (?,?,?,?,?)',
        [sid, 'r$sid', 'response', Uint8List(4096), 4096],
      );
    }

    DbCapManager.instance.maybeSweep(capBytes: 1);
    expect(dao.getSession(shared), isNotNull);
    expect(dao.getBody(shared, 'r$shared', 'response'), isNotNull);
    expect(dao.getSession(done), isNull, reason: 'an ended session is still evictable');
  });
}
