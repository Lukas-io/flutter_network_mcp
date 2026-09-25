import 'dart:io';

import 'package:flutter_network_mcp/src/state/log_buffer.dart';
import 'package:flutter_network_mcp/src/state/session.dart';
import 'package:flutter_network_mcp/src/storage/capture_writer.dart';
import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/tools/network_attach.dart';
import 'package:flutter_network_mcp/src/util/scope.dart';
import 'package:flutter_network_mcp/src/vm/log_stream.dart';
import 'package:flutter_network_mcp/src/vm/vm_client.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  final registry = SessionRegistry.instance;

  AttachedSession fake(int id, String uri,
          {String? app, String? project, int activity = 0}) =>
      AttachedSession(
        id: id,
        appName: app ?? 'Flutter - Device: iPhone 17 - Package: app$id',
        vmServiceUri: uri,
        vm: VmClient(),
        captureWriter: CaptureWriter(),
        logBuffer: LogBuffer(),
        logStream: LogStreamSubscriber(),
        attachedAt: DateTime.now(),
        httpProfilingEnabled: true,
        socketProfilingEnabled: false,
        projectPath: project,
      )..lastActivityMs = activity;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('fnm-liveness-');
    CapturesDatabase.open(dataDir: dir.path);
  });

  tearDown(() async {
    await registry.detachAll();
    for (final d in registry.dead.toList()) {
      registry.forgetDead(d.sessionId);
    }
    CapturesDatabase.instance.close();
    dir.deleteSync(recursive: true);
  });

  test('markDead frees the slot, ends the row, and is remembered', () {
    final dao = CapturesDao();
    final sid = dao.createSession(
        appName: 'a', vmServiceUri: 'ws://a', isolateId: null, projectPath: '/p');
    registry.register(fake(sid, 'ws://a'));
    expect(registry.liveCount, 1);
    registry.markDead(registry.attachedById(sid)!, 'test');
    expect(registry.liveCount, 0);
    expect(registry.deadById(sid)?.reason, 'test');
    final row = dao.rawSelect('SELECT ended_at FROM sessions WHERE id=$sid').first;
    expect(row['ended_at'], isNotNull);
  });

  test('a dead session read carries the note and movedTo', () {
    registry.register(fake(7, 'ws://old', app: 'Flutter - Device: iPhone 17 - Package: shop'));
    registry.markDead(registry.attachedById(7)!, 'app exited');
    registry.recordLiveApps({'ws://new': 'Flutter - Device: iPhone 17 - Package: shop'});
    final (scope, err) = resolveScope({'sessionId': 7});
    expect(err, isNull);
    expect(scope!.isLive, isFalse);
    expect(scope.note, contains('no longer reachable'));
    expect(scope.note, contains('ws://new'));
  });

  test('bare reads pick the project session, else the most recent', () {
    registry.register(fake(1, 'ws://1', project: '/other', activity: 100));
    registry.register(fake(2, 'ws://2', project: Directory.current.path, activity: 5));
    final (scope, err) = resolveScope(const {});
    expect(err, isNull);
    expect(scope!.sessionId, 2);
    expect(scope.pickedBy, 'project');
    expect(scope.others.single['sessionId'], 1);

    registry.unregister('ws://2');
    registry.register(fake(3, 'ws://3', project: '/elsewhere', activity: 50));
    final (s2, _) = resolveScope(const {});
    expect(s2!.sessionId, 1, reason: 'no project match → most recently touched');
    expect(s2.pickedBy, 'recent');
  });

  test('orphan sweep ends open rows that nothing holds', () {
    final dao = CapturesDao();
    final a = dao.createSession(appName: 'a', vmServiceUri: 'ws://a', isolateId: null, projectPath: null);
    final b = dao.createSession(appName: 'b', vmServiceUri: 'ws://b', isolateId: null, projectPath: null);
    expect(dao.endOrphanedSessions(keepOpen: {b}), 1);
    final rows = dao.rawSelect('SELECT id, ended_at, note FROM sessions ORDER BY id');
    expect(rows.firstWhere((r) => r['id'] == a)['note'], contains('orphaned'));
    expect(rows.firstWhere((r) => r['id'] == b)['ended_at'], isNull);
  });

  test('in-flight lock admits one attach per key', () {
    final f = AttachInFlight.instance;
    expect(f.claim('ws://x'), isTrue);
    expect(f.claim('ws://x'), isFalse);
    f.release('ws://x');
    expect(f.claim('ws://x'), isTrue);
    f.release('ws://x');
  });
}
