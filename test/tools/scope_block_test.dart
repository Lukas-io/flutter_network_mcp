import 'dart:async';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:flutter_network_mcp/src/state/log_buffer.dart';
import 'package:flutter_network_mcp/src/state/session.dart';
import 'package:flutter_network_mcp/src/storage/capture_writer.dart';
import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/tools/network_diff_session.dart';
import 'package:flutter_network_mcp/src/tools/network_drift.dart';
import 'package:flutter_network_mcp/src/tools/network_report.dart';
import 'package:flutter_network_mcp/src/vm/log_stream.dart';
import 'package:flutter_network_mcp/src/vm/vm_client.dart';
import 'package:test/test.dart';

/// network_drift, network_diff_session and network_report say which session
/// they read, like every other read tool.
void main() {
  late Directory dir;
  late CapturesDao dao;
  var vm = 0;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('scope_block_test_');
    CapturesDatabase.open(dataDir: dir.path);
    dao = CapturesDao();
  });

  tearDown(() async {
    Session.instance.viewedSessionId = null;
    await SessionRegistry.instance.detachAll();
    CapturesDatabase.instance.close();
    dir.deleteSync(recursive: true);
  });

  int session({bool ended = true}) {
    final id = dao.createSession(
        appName: 'app', vmServiceUri: 'ws://s${vm++}', isolateId: null, projectPath: null);
    if (ended) dao.endSession(id);
    return id;
  }

  void req(int sid, String path) {
    CapturesDatabase.instance.raw.execute(
      'INSERT INTO http_requests(session_id, vm_id, method, url, host, path, '
      'status_code, start_us, duration_us) VALUES (?,?,?,?,?,?,?,?,?)',
      [sid, 'v${vm++}', 'GET', 'https://api.x$path', 'api.x', path, 200, 1000, 1000],
    );
  }

  Future<Map<String, Object?>> call(
      FutureOr<CallToolResult> Function(CallToolRequest) tool,
      Map<String, Object?> args) async {
    final res = await tool(CallToolRequest(name: 't', arguments: args));
    return res.structuredContent!;
  }

  test('each tool returns a scope block for the session it read', () async {
    final base = session();
    final cur = session();
    req(base, '/a');
    req(cur, '/a');
    for (final tool in [networkDrift, networkReport]) {
      final out = await call(tool, {'sessionId': cur});
      expect((out['scope'] as Map)['sessionId'], cur);
    }
    final diff = await call(networkDiffSession, {'sessionId': cur, 'baselineSessionId': base});
    expect((diff['scope'] as Map)['sessionId'], cur);
  });

  test('a view shadowing a live session is flagged in warnings', () async {
    final live = session(ended: false);
    SessionRegistry.instance.register(AttachedSession(
      id: live,
      appName: 'live',
      vmServiceUri: 'ws://live',
      vm: VmClient(),
      captureWriter: CaptureWriter(),
      logBuffer: LogBuffer(),
      logStream: LogStreamSubscriber(),
      attachedAt: DateTime.now(),
      httpProfilingEnabled: true,
      socketProfilingEnabled: false,
    ));
    final viewed = session();
    final base = session();
    req(viewed, '/a');
    req(base, '/a');
    Session.instance.viewedSessionId = viewed;
    for (final (tool, args) in [
      (networkDrift, const <String, Object?>{}),
      (networkReport, const <String, Object?>{}),
      (networkDiffSession, {'baselineSessionId': base}),
    ]) {
      final out = await call(tool, args);
      expect((out['scope'] as Map)['note'], contains('HISTORY'));
      expect((out['warnings'] as List).join(' '), contains('HISTORY'));
    }
  });

  group('network_diff_session baseline', () {
    test('a baseline that does not exist is not_found', () async {
      final cur = session();
      req(cur, '/a');
      final out = await call(networkDiffSession, {'sessionId': cur, 'baselineSessionId': 9999});
      expect(out['errorKind'], 'not_found');
      expect(out['error'], contains('does not exist'));
      expect(out['nextSteps'], isNotEmpty);
    });

    test('a baseline with no requests is not_found, not all-new', () async {
      final base = session();
      final cur = session();
      req(cur, '/a');
      final out = await call(networkDiffSession, {'sessionId': cur, 'baselineSessionId': base});
      expect(out['errorKind'], 'not_found');
      expect(out.containsKey('newEndpoints'), isFalse);
    });

    test('an empty current session warns that every endpoint reads as gone', () async {
      final base = session();
      final cur = session();
      req(base, '/a');
      final out = await call(networkDiffSession, {'sessionId': cur, 'baselineSessionId': base});
      expect((out['goneEndpoints'] as List), hasLength(1));
      expect((out['warnings'] as List).join(' '), contains('no captured HTTP'));
    });
  });
}
