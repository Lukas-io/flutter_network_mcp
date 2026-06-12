import 'dart:convert';
import 'dart:io';

import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/telemetry/audit_log.dart';
import 'package:flutter_network_mcp/src/telemetry/telemetry_env.dart';
import 'package:flutter_network_mcp/src/telemetry/usage_reporter.dart';
import 'package:test/test.dart';

/// #79 Phase 3: the usage-rollup shipper. The collector endpoint is empty in
/// the shipped binary (Path B), so these exercise the audit-log-only path:
/// build a privacy-safe aggregate, record it, advance the watermark.
void main() {
  // Distinctive correlation ids: 'o' and 'r' are not hex, so they can never
  // appear as a substring of the hex machineHash and false-trip the no-PII
  // assertion below.
  List<Map<String, Object?>> sampleRows() => [
        {
          'id': 1,
          'ts_ms': 1000,
          'correlation_id': 'corrOne',
          'tool': 'network_list',
          'outcome': 'ok',
          'duration_ms': 40,
          'result_bytes': 1800,
        },
        {
          'id': 2,
          'ts_ms': 1100,
          'correlation_id': 'corrOne',
          'tool': 'network_get',
          'outcome': 'ok',
          'duration_ms': 12,
          'result_bytes': 500,
        },
        {
          'id': 3,
          'ts_ms': 2000,
          'correlation_id': 'corrTwo',
          'tool': 'network_list',
          'outcome': 'error',
          'duration_ms': 5,
          'result_bytes': 0,
        },
      ];

  group('buildUsagePayload (pure, privacy-safe rollup)', () {
    test('carries kind, version, machineHash, window, aggregates', () {
      final p = buildUsagePayload(rows: sampleRows(), dataDir: '/tmp/x');
      expect(p['kind'], 'usage_rollup');
      expect(p['version'], isA<String>());
      expect((p['machineHash'] as String).length, 24);
      final w = p['window'] as Map;
      expect(w['firstEventMs'], 1000);
      expect(w['lastEventMs'], 2000);
      expect(w['toEventId'], 3);
      expect(p['totalEvents'], 3);
      expect(p['totalTurns'], 2);
      expect((p['tools'] as List), isNotEmpty);
    });

    test('window.toEventId is the MAX id even when rows are not id-ordered',
        () {
      final s = sampleRows();
      final shuffled = [s[2], s[0], s[1]];
      final w = buildUsagePayload(rows: shuffled, dataDir: '/x')['window']
          as Map<String, Object?>;
      expect(w['toEventId'], 3);
      expect(w['firstEventMs'], 1000);
      expect(w['lastEventMs'], 2000);
    });

    test('raw correlation ids never leak into the payload', () {
      final p = buildUsagePayload(rows: sampleRows(), dataDir: '/x');
      final json = jsonEncode(p);
      expect(json, isNot(contains('corrOne')));
      expect(json, isNot(contains('corrTwo')));
      // The aggregate IS keyed by tool name, which is fine to ship.
      expect(json, contains('network_list'));
    });
  });

  group('telemetry_env identity + opt-out', () {
    test('telemetryDisabled honors true / 1 / yes / on (case-insensitive)',
        () {
      for (final v in ['true', '1', 'yes', 'on', 'TRUE', ' On ']) {
        expect(
          telemetryDisabled({'FLUTTER_NETWORK_MCP_NO_TELEMETRY': v}),
          isTrue,
          reason: v,
        );
      }
      expect(
        telemetryDisabled({'FLUTTER_NETWORK_MCP_NO_TELEMETRY': 'false'}),
        isFalse,
      );
      expect(telemetryDisabled({}), isFalse);
    });

    test('machineHash is stable, 24 hex chars, and dataDir-specific', () {
      final a = machineHash('/home/a');
      final b = machineHash('/home/a');
      final c = machineHash('/home/b');
      expect(a, b);
      expect(a, isNot(c));
      expect(a.length, 24);
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(a), isTrue);
    });
  });

  group('UsageReporter.ship (watermark idempotency, audit-log-only)', () {
    late Directory dir;
    late CapturesDao dao;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('usage_ship_test_');
      CapturesDatabase.open(dataDir: dir.path);
      dao = CapturesDao();
      UsageReporter.envForTest = {}; // never opted out, regardless of shell
      // Force audit-log-only so tests never POST to the real (baked)
      // collector, regardless of kCollectorEndpoint.
      UsageReporter.endpointForTest = '';
    });
    tearDown(() {
      UsageReporter.envForTest = null;
      UsageReporter.endpointForTest = null;
      CapturesDatabase.instance.close();
      dir.deleteSync(recursive: true);
    });

    void seed(int n) {
      for (var i = 0; i < n; i++) {
        dao.insertToolEvent(
          tsMs: 1000 + i,
          correlationId: 'c',
          tool: 'network_list',
          outcome: 'ok',
          durationMs: 10,
          resultBytes: 100,
        );
      }
    }

    File auditFile() => File('${dir.path}/${AuditLog.fileName}');
    File stateFile() => File('${dir.path}/${UsageReporter.stateFileName}');

    test('first ship records to the audit log and advances the watermark',
        () async {
      seed(3);
      final r = await UsageReporter.ship(dataDir: dir.path);
      expect(r.shipped, isTrue);
      expect(r.events, 3);
      expect(r.toEventId, 3);
      expect(r.posted, isFalse, reason: 'collector not configured');

      expect(auditFile().existsSync(), isTrue);
      final verified = AuditLog.verify(dir.path);
      expect(verified.intact, isTrue);
      expect(verified.totalEntries, 1);

      final state = jsonDecode(stateFile().readAsStringSync()) as Map;
      expect(state['lastShippedEventId'], 3);
      expect(state['shipCount'], 1);
    });

    test('re-ship with no new events is a no-op (no second audit entry)',
        () async {
      seed(3);
      await UsageReporter.ship(dataDir: dir.path);
      final r2 = await UsageReporter.ship(dataDir: dir.path);
      expect(r2.shipped, isFalse);
      expect(r2.events, 0);
      expect(AuditLog.verify(dir.path).totalEntries, 1);
    });

    test('only events after the watermark ship on the next run', () async {
      seed(2);
      final r1 = await UsageReporter.ship(dataDir: dir.path);
      expect(r1.toEventId, 2);

      seed(3); // ids 3, 4, 5
      final r2 = await UsageReporter.ship(dataDir: dir.path);
      expect(r2.shipped, isTrue);
      expect(r2.events, 3);
      expect(r2.fromEventId, 2);
      expect(r2.toEventId, 5);
      expect(AuditLog.verify(dir.path).totalEntries, 2);
    });

    test('dry run builds the payload but writes nothing', () async {
      seed(2);
      final r = await UsageReporter.ship(dataDir: dir.path, dryRun: true);
      expect(r.shipped, isFalse);
      expect(r.dryRun, isTrue);
      expect(r.events, 2);
      expect(r.payloadJson, isNotNull);
      expect(auditFile().existsSync(), isFalse);
      expect(stateFile().existsSync(), isFalse);
    });

    test('empty capture ships nothing', () async {
      final r = await UsageReporter.ship(dataDir: dir.path);
      expect(r.shipped, isFalse);
      expect(r.events, 0);
      expect(auditFile().existsSync(), isFalse);
    });

    test('opt-out short-circuits the ship', () async {
      seed(3);
      UsageReporter.envForTest = {'FLUTTER_NETWORK_MCP_NO_USAGE': 'true'};
      final r = await UsageReporter.ship(dataDir: dir.path);
      expect(r.shipped, isFalse);
      expect(r.message, contains('disabled'));
      expect(auditFile().existsSync(), isFalse);
    });
  });
}
