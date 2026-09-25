import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:flutter_network_mcp/src/state/log_buffer.dart';
import 'package:flutter_network_mcp/src/state/session.dart';
import 'package:flutter_network_mcp/src/storage/capture_writer.dart';
import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/tools/network_list.dart';
import 'package:flutter_network_mcp/src/vm/log_stream.dart';
import 'package:flutter_network_mcp/src/vm/vm_client.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

/// A VM whose HTTP profile is a fixed list per isolate; `updatedSince` keeps
/// requests that started after it, and `failing` isolates throw.
class _FakeVm extends VmClient {
  _FakeVm(this.requestsByIsolate);

  final Map<String, List<HttpProfileRequest>> requestsByIsolate;
  final Set<String> failing = {};
  int clockUs = 1000000;

  @override
  List<IsolateInfo> get httpProfilingIsolates =>
      [for (final id in requestsByIsolate.keys) IsolateInfo(id: id)];

  @override
  Future<HttpProfile> getHttpProfileForIsolate(
    String isolateId, {
    DateTime? updatedSince,
  }) async {
    if (failing.contains(isolateId)) {
      throw StateError('isolate $isolateId did not answer');
    }
    return HttpProfile(
      timestamp: DateTime.fromMicrosecondsSinceEpoch(clockUs),
      requests: [
        for (final r in requestsByIsolate[isolateId]!)
          if (updatedSince == null || r.startTime.isAfter(updatedSince)) r,
      ],
    );
  }
}

HttpProfileRequest _req(String id, int startUs, {String iso = 'i1'}) =>
    HttpProfileRequest(
      id: id,
      isolateId: iso,
      method: 'GET',
      uri: Uri.parse('https://api.example.com/$id'),
      events: const [],
      startTime: DateTime.fromMicrosecondsSinceEpoch(startUs),
    );

void main() {
  late Directory dir;
  late CapturesDao dao;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('network_list_live_test_');
    CapturesDatabase.open(dataDir: dir.path);
    dao = CapturesDao();
  });

  tearDown(() async {
    Session.instance.viewedSessionId = null;
    await SessionRegistry.instance.detachAll();
    CapturesDatabase.instance.close();
    dir.deleteSync(recursive: true);
  });

  _FakeVm attach(Map<String, List<HttpProfileRequest>> profile) {
    final sid = dao.createSession(
        appName: 'app', vmServiceUri: 'ws://live', isolateId: null, projectPath: null);
    final vm = _FakeVm(profile);
    SessionRegistry.instance.register(AttachedSession(
      id: sid,
      appName: 'app',
      vmServiceUri: 'ws://live',
      vm: vm,
      captureWriter: CaptureWriter(),
      logBuffer: LogBuffer(),
      logStream: LogStreamSubscriber(),
      attachedAt: DateTime.now(),
      httpProfilingEnabled: true,
      socketProfilingEnabled: false,
    ));
    return vm;
  }

  Future<Map<String, Object?>> list([Map<String, Object?> args = const {}]) async {
    final res = await networkList(CallToolRequest(name: 'network_list', arguments: args));
    return res.structuredContent!;
  }

  List<String> ids(Map<String, Object?> r) =>
      [for (final e in (r['requests'] as List).cast<Map<String, Object?>>()) e['id'] as String];

  test('rows past limit come back on the next incremental read', () async {
    attach({
      'i1': [for (var i = 1; i <= 5; i++) _req('r$i', i * 1000)],
    });

    final first = await list({'limit': 2});
    expect(ids(first), ['r5', 'r4']);
    expect(first['remaining'], 3);

    final second = await list({'limit': 2});
    expect(ids(second), ['r3', 'r2']);
    expect(second['remaining'], 1);

    final third = await list({'limit': 2});
    expect(ids(third), ['r1']);
    expect(third.containsKey('remaining'), isFalse);

    final fourth = await list({'limit': 2});
    expect(ids(fourth), isEmpty);
  });

  test('carried rows merge newest-first with requests that arrived since', () async {
    final vm = attach({
      'i1': [for (var i = 1; i <= 3; i++) _req('r$i', i * 1000)],
    });
    expect(ids(await list({'limit': 1})), ['r3']);

    vm.requestsByIsolate['i1']!.add(_req('r9', 2000000));
    vm.clockUs = 3000000;
    final next = await list({'limit': 5});
    expect(ids(next), ['r9', 'r2', 'r1']);
    expect(next.containsKey('remaining'), isFalse);
  });

  test('every isolate failing falls back to the DB snapshot', () async {
    final vm = attach({
      'i1': [_req('a', 1000)],
      'i2': [_req('b', 2000, iso: 'i2')],
    });
    vm.failing.addAll(['i1', 'i2']);
    final r = await list();
    expect(r['source'], 'live-db-fallback');
  });

  test('one failing isolate is reported and retried on the next read', () async {
    final vm = attach({
      'i1': [_req('a', 1000)],
      'i2': [_req('b', 2000, iso: 'i2')],
    });
    vm.failing.add('i2');
    final r = await list();
    expect(r['source'], 'live');
    expect(ids(r), ['a']);
    expect(r['partial'], isTrue);
    expect(r['failedIsolates'], ['i2']);
    expect((r['warnings'] as List).join(' '), contains('i2'));

    vm.failing.clear();
    vm.clockUs = 5000000;
    expect(ids(await list()), ['b']);
  });

  group('history empty result', () {
    int endedSession() {
      final id = dao.createSession(
          appName: 'old', vmServiceUri: 'ws://old', isolateId: null, projectPath: null);
      dao.endSession(id);
      return id;
    }

    test('does not suggest session_close without an open view', () async {
      final id = endedSession();
      final r = await list({'sessionId': id});
      expect(r['source'], 'history');
      expect((r['nextSteps'] as List).join(' '), isNot(contains('session_close')));
    });

    test('suggests session_close while that session is opened', () async {
      final id = endedSession();
      Session.instance.viewedSessionId = id;
      final r = await list();
      expect((r['nextSteps'] as List).join(' '), contains('session_close'));
    });
  });
}
