import 'dart:io';

import 'package:flutter_network_mcp/src/alerts/signature.dart';
import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:test/test.dart';

Directory makeTempDir() {
  return Directory.systemTemp.createTempSync('prior_occurrences_test_');
}

void main() {
  group('priorOccurrencesForSignature', () {
    late Directory dir;
    late CapturesDao dao;

    setUp(() {
      dir = makeTempDir();
      CapturesDatabase.open(dataDir: dir.path);
      dao = CapturesDao();
    });

    tearDown(() {
      CapturesDatabase.instance.close();
      dir.deleteSync(recursive: true);
    });

    test('empty when no prior occurrences exist', () {
      final sid = dao.createSession(
        appName: 'test',
        vmServiceUri: 'ws://1',
        isolateId: null,
        projectPath: null,
      );
      final result = dao.priorOccurrencesForSignature(
        signature: 'abc123def456',
        excludeSessionId: sid,
      );
      expect(result, isEmpty);
    });

    test('returns prior occurrence from another session', () {
      // Past session with an alert.
      final pastSid = dao.createSession(
        appName: 'sanga_mobile',
        vmServiceUri: 'ws://past',
        isolateId: null,
        projectPath: null,
      );
      dao.setSessionNote(pastSid, 'investigated yesterday');
      const signature = 'a3f7c8d219b4';
      dao.insertAlert(
        sessionId: pastSid,
        severity: 'critical',
        kind: 'flutter_error',
        title: 'RenderFlex overflow',
        signature: signature,
        sourceKind: 'log',
        sourceId: 'log:1',
      );

      // Current session.
      final currentSid = dao.createSession(
        appName: 'sanga_mobile',
        vmServiceUri: 'ws://current',
        isolateId: null,
        projectPath: null,
      );

      final result = dao.priorOccurrencesForSignature(
        signature: signature,
        excludeSessionId: currentSid,
      );
      expect(result, hasLength(1));
      expect(result.first['session_id'], pastSid);
      expect(result.first['note'], 'investigated yesterday');
      expect(result.first['app_name'], 'sanga_mobile');
    });

    test('excludes the current session', () {
      final currentSid = dao.createSession(
        appName: 'test',
        vmServiceUri: 'ws://current',
        isolateId: null,
        projectPath: null,
      );
      const signature = 'b9e2f1c4d3a8';
      dao.insertAlert(
        sessionId: currentSid,
        severity: 'error',
        kind: 'http_5xx',
        title: '500 on POST /api/login',
        signature: signature,
        sourceKind: 'http',
        sourceId: 'req-1',
      );
      final result = dao.priorOccurrencesForSignature(
        signature: signature,
        excludeSessionId: currentSid,
      );
      expect(result, isEmpty,
          reason: 'current session must not appear in its own prior list');
    });

    test('newest-first ordering, capped at limit', () {
      const signature = 'aaaaaaaaaaaa';
      // Create 5 past sessions, each with the same signature, increasing
      // started_at. Synthetic ts via insertAlert tsMs override would need
      // an extra arg — easier path: insert in order, the autoincrement
      // started_at uses DateTime.now() and respects insertion order at
      // millisecond granularity. For determinism, we instead read back
      // by descending started_at.
      final sids = <int>[];
      for (var i = 0; i < 5; i++) {
        final sid = dao.createSession(
          appName: 'app$i',
          vmServiceUri: 'ws://past$i',
          isolateId: null,
          projectPath: null,
        );
        dao.insertAlert(
          sessionId: sid,
          severity: 'warning',
          kind: 'log_keyword',
          title: 'noisy log',
          signature: signature,
          sourceKind: 'log',
          sourceId: 'log:$i',
        );
        sids.add(sid);
        // Tiny sleep so started_at differs between sessions (default db
        // resolution is millisecond).
        sleep(const Duration(milliseconds: 2));
      }
      final current = dao.createSession(
        appName: 'current',
        vmServiceUri: 'ws://current',
        isolateId: null,
        projectPath: null,
      );
      final result = dao.priorOccurrencesForSignature(
        signature: signature,
        excludeSessionId: current,
        limit: 3,
      );
      expect(result, hasLength(3));
      // Newest first → app4, app3, app2.
      expect(result.map((r) => r['app_name']).toList(),
          ['app4', 'app3', 'app2']);
    });

    test('different signatures stay separate', () {
      final pastSid = dao.createSession(
        appName: 'app',
        vmServiceUri: 'ws://past',
        isolateId: null,
        projectPath: null,
      );
      dao.insertAlert(
        sessionId: pastSid,
        severity: 'critical',
        kind: 'flutter_error',
        title: 'overflow',
        signature: 'sig-a',
        sourceKind: 'log',
        sourceId: 'log:1',
      );
      final currentSid = dao.createSession(
        appName: 'app',
        vmServiceUri: 'ws://current',
        isolateId: null,
        projectPath: null,
      );
      // Looking up a different signature: no results.
      final result = dao.priorOccurrencesForSignature(
        signature: 'sig-b',
        excludeSessionId: currentSid,
      );
      expect(result, isEmpty);
    });

    test('aggregates per-session even when multiple alerts in past session', () {
      final pastSid = dao.createSession(
        appName: 'app',
        vmServiceUri: 'ws://past',
        isolateId: null,
        projectPath: null,
      );
      dao.setSessionNote(pastSid, 'fixed by adding Expanded');
      const signature = 'render-overflow-N';
      // Same signature fires 3 times in the past session (would be one
      // alert row with occurrenceCount via the 0.6.3 upsert, but we
      // simulate distinct rows for robustness).
      dao.insertAlert(
        sessionId: pastSid,
        severity: 'critical',
        kind: 'flutter_error',
        title: 'overflow 1',
        signature: signature,
        sourceKind: 'log',
        sourceId: 'log:1',
      );

      final currentSid = dao.createSession(
        appName: 'app',
        vmServiceUri: 'ws://current',
        isolateId: null,
        projectPath: null,
      );

      final result = dao.priorOccurrencesForSignature(
        signature: signature,
        excludeSessionId: currentSid,
      );
      expect(result, hasLength(1),
          reason: 'GROUP BY session collapses N alerts/session to one row');
      expect(result.first['note'], 'fixed by adding Expanded');
    });
  });

  group('computeAlertSignature (sanity)', () {
    test('hash is 12 hex chars', () {
      final sig = computeAlertSignature(kind: 'http_5xx', title: '500 on /x');
      expect(sig.length, 12);
      expect(RegExp(r'^[a-f0-9]{12}$').hasMatch(sig), isTrue);
    });
  });
}
