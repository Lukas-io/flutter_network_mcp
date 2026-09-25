import 'dart:io';

import 'dart:async';

import 'package:dart_mcp/server.dart';
import 'package:flutter_network_mcp/src/storage/capture_writer.dart';
import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/tools/body_fetch.dart';
import 'package:flutter_network_mcp/src/util/scope.dart';
import 'package:flutter_network_mcp/src/vm/vm_client.dart';
import 'package:vm_service/vm_service.dart' show HttpProfileRequest;
import 'package:test/test.dart';

/// #95/#96/#100: bodies stranded when a session ends, plus the honesty of the
/// messages that report the gap.
/// A VM whose body fetches never answer, or that has already disconnected.
class _StuckVm extends VmClient {
  _StuckVm({this.connected = true});
  final bool connected;
  int fetches = 0;

  @override
  bool get isConnected => connected;
  @override
  String? get isolateId => 'iso';
  @override
  List<IsolateInfo> get httpProfilingIsolates => const [];
  @override
  Future<List<IsolateInfo>> discoverHttpProfilingIsolates() async => const [];
  @override
  Future<HttpProfileRequest> getHttpProfileRequestForIsolate(
      String isolateId, String requestId) {
    fetches++;
    if (!connected) throw StateError('VM service is not connected');
    return Completer<HttpProfileRequest>().future;
  }
}

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

    test('a history view of a session still open elsewhere is told to retry', () {
      insertReq('r1');
      final scope = Scope(sessionId: sid, appName: 'app', isLive: false);
      final s = structured(
          noBodyResult(scope, 'r1', 'response', 'history', null));
      final warnings = (s['warnings'] as List).cast<String>().join(' ');
      expect(warnings, contains('Retry'));
      expect(warnings, isNot(contains('unrecoverable')));
    });

    test('an ended session is told the bytes are unrecoverable', () {
      insertReq('r1');
      dao.endSession(sid);
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

    test('a VM that never answers cannot hold the flush past its deadline', () async {
      for (var i = 0; i < 20; i++) {
        insertReq('r$i');
      }
      final vm = _StuckVm();
      final writer = CaptureWriter()..start(vm, sid);
      final watch = Stopwatch()..start();
      await writer.flushPendingBodies(deadline: const Duration(milliseconds: 2500));
      watch.stop();
      await writer.stop();
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 4000)));
      expect(vm.fetches, lessThanOrEqualTo(4));
    });

    test('a disconnected VM ends the flush at once instead of spinning', () async {
      for (var i = 0; i < 20; i++) {
        insertReq('r$i');
      }
      final vm = _StuckVm(connected: false);
      final writer = CaptureWriter()..start(vm, sid);
      final watch = Stopwatch()..start();
      await writer.flushPendingBodies();
      watch.stop();
      await writer.stop();
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 500)));
      expect(vm.fetches, lessThanOrEqualTo(1));
    });
  });
}
