import 'dart:io';

import 'package:flutter_network_mcp/src/alerts/alert_retention.dart';
import 'package:flutter_network_mcp/src/alerts/alert_rules.dart';
import 'package:flutter_network_mcp/src/state/log_buffer.dart';
import 'package:flutter_network_mcp/src/state/session.dart';
import 'package:flutter_network_mcp/src/storage/capture_writer.dart';
import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/vm/log_stream.dart';
import 'package:flutter_network_mcp/src/vm/vm_client.dart';
import 'package:test/test.dart';

/// Alert retention: old alerts from non-attached sessions auto-expire so the
/// pending banner reflects recent state; live sessions' alerts are protected;
/// 0 disables it.
void main() {
  late Directory dir;
  late CapturesDao dao;
  const dayMs = 86400000;
  const nowMs = 1783000000000; // fixed clock for the tests

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

  void insertAlert(int sid, int tsMs) {
    CapturesDatabase.instance.raw.execute(
      'INSERT INTO alerts(session_id, ts_ms, severity, kind, title) '
      'VALUES (?,?,?,?,?)',
      [sid, tsMs, 'error', 'http_5xx', '500 on x'],
    );
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('alert_retention_test_');
    CapturesDatabase.open(dataDir: dir.path);
    dao = CapturesDao();
    AlertRules.instance.alertRetentionDays = 14; // reset per test
  });

  tearDown(() async {
    await SessionRegistry.instance.detachAll();
    AlertRules.instance.alertRetentionDays = 14;
    CapturesDatabase.instance.close();
    dir.deleteSync(recursive: true);
  });

  int alertCount() => CapturesDatabase.instance.raw
      .select('SELECT COUNT(*) c FROM alerts')
      .first['c'] as int;

  test('expires alerts older than the window, keeps recent ones', () {
    final sid = dao.createSession(
        appName: 'a', vmServiceUri: 'ws://x', isolateId: null, projectPath: null);
    insertAlert(sid, nowMs - 20 * dayMs); // old — expire
    insertAlert(sid, nowMs - 15 * dayMs); // old — expire
    insertAlert(sid, nowMs - 2 * dayMs); //  recent — keep
    expect(alertCount(), 3);

    final ret = AlertRetention(now: () => nowMs);
    final deleted = ret.sweep();
    expect(deleted, 2);
    expect(alertCount(), 1, reason: 'only the 2-day-old alert survives');
  });

  test('protects alerts of a currently-attached session, however old', () {
    final live = dao.createSession(
        appName: 'live', vmServiceUri: 'ws://live', isolateId: null,
        projectPath: null);
    SessionRegistry.instance.register(fakeSession(live, 'ws://live'));
    insertAlert(live, nowMs - 100 * dayMs); // ancient but LIVE — keep

    final dead = dao.createSession(
        appName: 'dead', vmServiceUri: 'ws://dead', isolateId: null,
        projectPath: null);
    insertAlert(dead, nowMs - 100 * dayMs); // ancient + not attached — expire

    final deleted = AlertRetention(now: () => nowMs).sweep();
    expect(deleted, 1);
    expect(
      CapturesDatabase.instance.raw
          .select('SELECT session_id FROM alerts')
          .map((r) => r['session_id'])
          .toList(),
      [live],
      reason: 'the live session keeps its ancient alert',
    );
  });

  test('retentionDays = 0 disables retention (keeps forever)', () {
    AlertRules.instance.alertRetentionDays = 0;
    final sid = dao.createSession(
        appName: 'a', vmServiceUri: 'ws://x', isolateId: null, projectPath: null);
    insertAlert(sid, nowMs - 1000 * dayMs);
    expect(AlertRetention(now: () => nowMs).sweep(), 0);
    expect(alertCount(), 1);
  });

  test('DAO expireOldAlerts is a no-op when nothing is old enough', () {
    final sid = dao.createSession(
        appName: 'a', vmServiceUri: 'ws://x', isolateId: null, projectPath: null);
    insertAlert(sid, nowMs);
    expect(
      dao.expireOldAlerts(cutoffMs: nowMs - dayMs, protectedSessionIds: {}),
      0,
    );
    expect(alertCount(), 1);
  });
}
