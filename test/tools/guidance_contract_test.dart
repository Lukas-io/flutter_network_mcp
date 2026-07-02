import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:flutter_network_mcp/src/state/log_buffer.dart';
import 'package:flutter_network_mcp/src/state/session.dart';
import 'package:flutter_network_mcp/src/storage/capture_writer.dart';
import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/tools/alerts_config.dart';
import 'package:flutter_network_mcp/src/tools/alerts_drain.dart';
import 'package:flutter_network_mcp/src/tools/network_attach.dart';
import 'package:flutter_network_mcp/src/tools/network_get.dart';
import 'package:flutter_network_mcp/src/tools/network_report.dart';
import 'package:flutter_network_mcp/src/tools/network_summarize.dart';
import 'package:flutter_network_mcp/src/tools/result.dart';
import 'package:flutter_network_mcp/src/tools/session_open.dart';
import 'package:flutter_network_mcp/src/util/guidance.dart';
import 'package:flutter_network_mcp/src/util/scope.dart';
import 'package:flutter_network_mcp/src/vm/log_stream.dart';
import 'package:flutter_network_mcp/src/vm/vm_client.dart';
import 'package:test/test.dart';

/// D1/D2 (audit RC8/RC6) contract: guidance must be a function of session
/// state. The forbidden pattern is a hint that is impossible in the state
/// that produced it — "drive the app" for an ended capture, "still live"
/// for a crashed one, "backfilling" for a writer that will never run again.
void main() {
  late Directory dir;
  late CapturesDao dao;

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

  setUp(() {
    dir = Directory.systemTemp.createTempSync('guidance_test_');
    CapturesDatabase.open(dataDir: dir.path);
    dao = CapturesDao();
  });

  tearDown(() async {
    Session.instance.viewedSessionId = null;
    await SessionRegistry.instance.detachAll();
    CapturesDatabase.instance.close();
    dir.deleteSync(recursive: true);
  });

  int endedSession() {
    final id = dao.createSession(
        appName: 'a', vmServiceUri: 'ws://e', isolateId: null, projectPath: null);
    dao.endSession(id);
    return id;
  }

  group('emptyCaptureHint / SessionStateView', () {
    test('ended session never says "Drive the app"', () async {
      final id = endedSession();
      for (final res in [
        await networkSummarize(CallToolRequest(
            name: 'network_summarize',
            arguments: {'sessionId': id, 'sinceMs': 0})),
        await networkReport(CallToolRequest(
            name: 'network_report', arguments: {'sessionId': id})),
        await alertsDrain(CallToolRequest(
            name: 'alerts_drain', arguments: {'sessionId': id})),
      ]) {
        final text = res.structuredContent.toString();
        expect(text, isNot(contains('Drive the app')),
            reason: 'ended session got a drive-the-app hint: $text');
        expect(text.contains('complete'), isTrue,
            reason: 'ended session should route to its complete capture');
      }
    });

    test('live attached session still says "Drive the app"', () async {
      final id = dao.createSession(
          appName: 'a', vmServiceUri: 'ws://live1', isolateId: null,
          projectPath: null);
      SessionRegistry.instance.register(fakeSession(id, 'ws://live1'));
      final res = await networkSummarize(CallToolRequest(
          name: 'network_summarize',
          arguments: {'sessionId': id, 'sinceMs': 0}));
      expect(res.structuredContent.toString(), contains('Drive the app'));
    });

    test('interrupted (no clean end) is called interrupted, not live', () {
      final id = dao.createSession(
          appName: 'a', vmServiceUri: 'ws://i', isolateId: null,
          projectPath: null);
      final state = SessionStateView.of(id);
      expect(state.isInterrupted, isTrue);
      expect(
          sessionStatusLabel(isAttached: false, endedAtMs: null), 'interrupted');
    });
  });

  group('network_get history body warnings (F12)', () {
    test('ended session says "never captured", not "backfilling"', () async {
      final id = endedSession();
      CapturesDatabase.instance.raw.execute(
        'INSERT INTO http_requests(session_id, vm_id, method, url, host, '
        'path, status_code, start_us, response_size) VALUES (?,?,?,?,?,?,?,?,?)',
        [id, 'r1', 'GET', 'https://x/a', 'x', '/a', 200, 1000, 55],
      );
      final res = await networkGet(CallToolRequest(
          name: 'network_get', arguments: {'sessionId': id, 'id': 'r1'}));
      final text = res.structuredContent.toString();
      expect(text, isNot(contains('backfilling')));
      expect(text, contains('never captured'));
    });
  });

  group('session_open tri-state (F11)', () {
    test('interrupted session is not "still live"', () async {
      final id = dao.createSession(
          appName: 'a', vmServiceUri: 'ws://z', isolateId: null,
          projectPath: null);
      final res = await sessionOpen(CallToolRequest(
          name: 'session_open', arguments: {'id': id}));
      final summary = res.structuredContent!['summary'].toString();
      expect(summary, isNot(contains('still live')));
      expect(summary, contains('interrupted'));
    });
  });

  group('scope shadowing (D2/F4)', () {
    test('view over live sessions carries a note, promoted to a warning', () {
      final ended = endedSession();
      final liveId = dao.createSession(
          appName: 'a', vmServiceUri: 'ws://live2', isolateId: null,
          projectPath: null);
      SessionRegistry.instance.register(fakeSession(liveId, 'ws://live2'));
      Session.instance.viewedSessionId = ended;

      final (scope, err) = resolveScope(const {});
      expect(err, isNull);
      expect(scope!.sessionId, ended);
      expect(scope.note, contains('HISTORY'));

      final res = jsonResult({'summary': 'x'}, scopeNote: scope.note);
      expect((res.structuredContent!['warnings'] as List).join(),
          contains('HISTORY'));
    });

    test('agent-initiated attach closes the stale view and says so', () {
      final ended = endedSession();
      Session.instance.viewedSessionId = ended;
      final result = <String, Object?>{'attached': true};
      closeStaleViewAfterAttach(result);
      expect(Session.instance.viewedSessionId, isNull);
      expect((result['warnings'] as List).join(), contains('history view'));
    });
  });

  group('alerts_config schema unification (F13)', () {
    test('rule count, toggles, and schema cover all 7 rules', () async {
      final res = await alertsConfig(
          CallToolRequest(name: 'alerts_config', arguments: const {}));
      final sc = res.structuredContent!;
      expect(sc['summary'].toString(), contains('7/7'));
      final rules =
          ((sc['config'] as Map)['rules'] as Map).keys.cast<String>();
      expect(rules, contains('http_anomaly'));

      final toggled = await alertsConfig(CallToolRequest(
          name: 'alerts_config',
          arguments: {
            'set': {
              'rules': {'http_anomaly': false}
            }
          }));
      final after =
          ((toggled.structuredContent!['config'] as Map)['rules'] as Map);
      expect(after['http_anomaly'], isFalse);
      // Restore for other tests (per-process singleton).
      await alertsConfig(CallToolRequest(name: 'alerts_config', arguments: {
        'set': {
          'rules': {'http_anomaly': true}
        }
      }));
    });
  });
}
