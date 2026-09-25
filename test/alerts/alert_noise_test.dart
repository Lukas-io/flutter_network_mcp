import 'dart:io';

import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/tools/result.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late CapturesDao dao;
  late int sid;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('alert_noise_');
    CapturesDatabase.open(dataDir: dir.path);
    dao = CapturesDao();
    sid = dao.createSession(
        appName: 'a', vmServiceUri: 'ws://x', isolateId: null, projectPath: null);
  });
  tearDown(() {
    CapturesDatabase.instance.close();
    dir.deleteSync(recursive: true);
  });

  test('only the first flutter_error of a session is critical', () {
    for (var i = 0; i < 3; i++) {
      dao.insertAlert(
        sessionId: sid,
        severity: 'critical',
        kind: 'flutter_error',
        title: 'Null check $i',
        signature: 'sig-$i',
        sourceKind: 'log',
        sourceId: 'log:$i',
      );
    }
    final sev = CapturesDatabase.instance.raw
        .select('SELECT severity FROM alerts WHERE session_id=? ORDER BY id', [sid])
        .map((r) => r['severity'])
        .toList();
    expect(sev, ['critical', 'error', 'error']);
    expect(dao.pendingAlertCount(sessionId: sid, severityMin: 'critical'), 1);
  });

  test('pending alerts are capped per session, oldest dropped', () {
    for (var i = 0; i < 205; i++) {
      dao.insertAlert(
        sessionId: sid,
        severity: 'warning',
        kind: 'log_keyword',
        title: 'k $i',
        signature: 'k-$i',
        tsMs: 1000 + i,
      );
    }
    expect(dao.capPendingAlerts(), 5);
    expect(dao.pendingAlertCount(sessionId: sid), 200);
    final oldest = CapturesDatabase.instance.raw
        .select('SELECT MIN(ts_ms) AS m FROM alerts WHERE session_id=?', [sid])
        .first['m'];
    expect(oldest, 1005);
  });

  test('replies without a session in scope carry no pendingAlerts', () {
    dao.insertAlert(
        sessionId: sid, severity: 'warning', kind: 'http_4xx', title: 't', signature: 's');
    final r = jsonResult({'summary': 'x'});
    final sc = r.structuredContent as Map<String, Object?>;
    expect(sc.containsKey('pendingAlerts'), isFalse);
    final scoped = jsonResult({'summary': 'x'}, scopeSessionId: sid);
    final sc2 = scoped.structuredContent as Map<String, Object?>;
    expect((sc2['pendingAlerts'] as Map)['count'], 1);
    expect((sc2['pendingAlerts'] as Map)['sessionId'], sid);
  });
}
