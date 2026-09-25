import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:flutter_network_mcp/src/alerts/alert_rules.dart';
import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/tools/alerts_clear.dart';
import 'package:flutter_network_mcp/src/tools/alerts_config.dart';
import 'package:flutter_network_mcp/src/tools/alerts_drain.dart';
import 'package:flutter_network_mcp/src/tools/alerts_peek.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late CapturesDao dao;
  late int sid;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('alert_severity_test_');
    CapturesDatabase.open(dataDir: dir.path);
    dao = CapturesDao();
    sid = dao.createSession(
        appName: 'a', vmServiceUri: 'ws://x', isolateId: null, projectPath: null);
  });

  tearDown(() {
    CapturesDatabase.instance.close();
    dir.deleteSync(recursive: true);
  });

  group('severity case', () {
    test('an uppercase severity is stored lowercase and passes severityMin', () {
      dao.insertAlert(
        sessionId: sid,
        severity: 'ERROR',
        kind: 'order_fail',
        title: 'order failed',
        signature: 'sig-upper',
      );
      final stored = CapturesDatabase.instance.raw
          .select('SELECT severity FROM alerts WHERE session_id=?', [sid])
          .first['severity'];
      expect(stored, 'error');
      expect(dao.pendingAlertCount(sessionId: sid, severityMin: 'warning'), 1);
    });

    test('a legacy uppercase row still passes severityMin', () {
      CapturesDatabase.instance.raw.execute(
        'INSERT INTO alerts(session_id, ts_ms, severity, kind, title) '
        'VALUES (?, 1, ?, ?, ?)',
        [sid, 'CRITICAL', 'order_fail', 'legacy'],
      );
      expect(dao.pendingAlertCount(sessionId: sid, severityMin: 'error'), 1);
    });

    test('a custom pattern severity is stored lowercase', () {
      dao.addAlertPattern(kind: 'k', regex: 'boom', severity: ' Warning ');
      expect(dao.listAlertPatterns().single['severity'], 'warning');
    });
  });

  group('an unknown severityMin is bad_argument', () {
    for (final (name, call) in [
      ('alerts_drain', alertsDrain),
      ('alerts_peek', alertsPeek),
      ('alerts_clear', alertsClear),
    ]) {
      test(name, () async {
        final r = await call(CallToolRequest(
            name: name, arguments: {'sessionId': sid, 'severityMin': 'loud'}));
        expect(r.isError, isTrue);
        expect(r.structuredContent!['errorKind'], 'bad_argument');
        expect(r.structuredContent!['error'], contains('loud'));
      });
    }
  });

  group('alerts_config set validation', () {
    late int slowBefore;
    setUp(() => slowBefore = AlertRules.instance.slowThresholdMs);
    tearDown(() => AlertRules.instance.slowThresholdMs = slowBefore);

    Future<CallToolResult> set(Object? value) => Future.value(alertsConfig(
        CallToolRequest(name: 'alerts_config', arguments: {'set': value})));

    test('a non-object set is bad_argument, not a crash', () async {
      final r = await set('slowThresholdMs=5000');
      expect(r.isError, isTrue);
      expect(r.structuredContent!['errorKind'], 'bad_argument');
    });

    test('nothing valid is bad_argument with the rejected values', () async {
      final r = await set({'slowThresholdMs': -1});
      expect(r.isError, isTrue);
      expect(r.structuredContent!['errorKind'], 'bad_argument');
      final rejected = r.structuredContent!['rejected'] as List;
      expect((rejected.single as Map)['field'], 'slowThresholdMs');
      expect(AlertRules.instance.slowThresholdMs, slowBefore);
    });

    test('valid values apply and the rest are reported', () async {
      final r = await set({
        'slowThresholdMs': 4321,
        'rules': {'no_such_rule': true, 'http_4xx': 'no'},
      });
      expect(r.isError, isFalse);
      final sc = r.structuredContent!;
      expect(sc['mutated'], isTrue);
      expect(sc['applied'], ['slowThresholdMs']);
      final fields = [for (final x in sc['rejected'] as List) (x as Map)['field']];
      expect(fields, ['rules.no_such_rule', 'rules.http_4xx']);
      expect(sc['summary'], contains('Rejected 2'));
      expect(AlertRules.instance.slowThresholdMs, 4321);
      expect(AlertRules.instance.http4xxEnabled, isTrue);
    });
  });
}
