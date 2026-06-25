import 'dart:convert';
import 'dart:io' as io;

import 'package:path/path.dart' as p;

import '../storage/captures_db.dart';
import '../storage/database.dart';
import '../tools/usage_stats.dart' show summarizeUsage;
import '../util/data_dir.dart';
import '../version.dart';
import 'audit_log.dart';
import 'telemetry_constants.dart';
import 'telemetry_env.dart';

/// Ships privacy-safe USAGE AGGREGATES to the maintainer collector (issue
/// #79, Phase 3). The local `tool_events` capture from Phase 1 becomes a
/// periodic rollup: per-tool counts, outcome + latency stats, and the
/// tool-to-next-tool transition graph (exactly what `usage_stats`
/// computes). Raw events never leave the machine; only the aggregate does.
///
/// Same trust model as crash telemetry ([TelemetryReporter]):
/// 1. **Audit log first** (always, when not opted out): the EXACT rollup
///    JSON is appended to the hash-chained `telemetry-audit.log` BEFORE any
///    network attempt, so `flutter_network_mcp audit show` shows precisely
///    what left (or would have left) the machine.
/// 2. **HTTPS POST** only when [kCollectorEndpoint] is non-empty. The
///    binary ships with an empty endpoint (Path B), so today this is
///    audit-log-only until the collector is deployed and the URL is baked.
///
/// Idempotent via a high-watermark: a tiny `usage-ship-state.json` in the
/// data dir records the last `tool_events.id` shipped, so re-running never
/// double-counts. Triggered two ways: fire-and-forget on server startup
/// ([maybeAutoShip], daily-gated) and explicitly via `flutter_network_mcp
/// usage ship`.
///
/// Opt out with `FLUTTER_NETWORK_MCP_NO_USAGE=true` (usage only) or
/// `FLUTTER_NETWORK_MCP_NO_TELEMETRY=true` (everything), the same flags
/// that gate usage capture.
class UsageReporter {
  /// Watermark + bookkeeping file in the data dir.
  static const String stateFileName = 'usage-ship-state.json';

  /// Auto-ship runs at most this often, so a flurry of MCP-host restarts
  /// writes one rollup per day, not one per launch.
  static const Duration autoShipMinInterval = Duration(hours: 24);

  /// Hard cap on events folded into a single rollup. Aggregates stay small
  /// regardless; this bounds the query + in-memory pass.
  static const int _maxEventsPerShip = 50000;

  /// Fire-and-forget startup hook. Daily-gated and never throws, so it is
  /// safe to `unawaited(...)` from `main` alongside the update check.
  static Future<void> maybeAutoShip() async {
    try {
      if (_optedOut()) return;
      final dir = resolveCandidateDataDir();
      if (dir == null) return;
      final last = _readState(dir).lastShippedAtMs;
      if (last != null &&
          DateTime.now().millisecondsSinceEpoch - last <
              autoShipMinInterval.inMilliseconds) {
        return;
      }
      await ship(dataDir: dir);
    } catch (_) {
    }
  }

  /// Builds + ships (or, with [dryRun], just builds) the rollup of every
  /// event newer than the stored watermark. Returns a [UsageShipResult]
  /// for the CLI to print. Never throws.
  static Future<UsageShipResult> ship({
    String? dataDir,
    bool dryRun = false,
  }) async {
    final dir = dataDir ?? resolveCandidateDataDir();
    if (dir == null) {
      return const UsageShipResult(
          shipped: false, message: 'could not resolve a data dir');
    }
    if (_optedOut()) {
      return const UsageShipResult(
          shipped: false,
          message: 'usage telemetry disabled (FLUTTER_NETWORK_MCP_NO_USAGE / '
              'NO_TELEMETRY)');
    }
    if (!CapturesDatabase.isOpen) {
      try {
        CapturesDatabase.open();
      } catch (e) {
        return UsageShipResult(
            shipped: false, message: 'could not open the capture DB ($e)');
      }
    }

    final state = _readState(dir);
    final List<Map<String, Object?>> rows;
    try {
      rows = CapturesDao().toolEventsAfterId(
        afterId: state.lastShippedEventId,
        limit: _maxEventsPerShip,
      );
    } catch (e) {
      return UsageShipResult(
          shipped: false, message: 'tool_events query failed ($e)');
    }
    if (rows.isEmpty) {
      return UsageShipResult(
        shipped: false,
        events: 0,
        fromEventId: state.lastShippedEventId,
        toEventId: state.lastShippedEventId,
        message: 'no new events since the last ship '
            '(watermark id=${state.lastShippedEventId})',
      );
    }

    final payload = buildUsagePayload(rows: rows, dataDir: dir);
    final toEventId = (payload['window'] as Map)['toEventId'] as int;
    final jsonStr = jsonEncode(payload);

    if (dryRun) {
      return UsageShipResult(
        shipped: false,
        dryRun: true,
        events: rows.length,
        fromEventId: state.lastShippedEventId,
        toEventId: toEventId,
        payloadJson: jsonStr,
        message: 'dry run: ${rows.length} event(s) would ship; nothing '
            'written',
      );
    }

    var auditWritten = true;
    try {
      AuditLog.append(dir, jsonStr);
    } catch (_) {
      auditWritten = false;
    }

    var posted = false;
    if (_endpoint.isNotEmpty) {
      try {
        final status =
            await postTelemetry(jsonStr).timeout(kTelemetryTimeout);
        posted = status >= 200 && status < 300;
      } catch (_) {
      }
    }

    _writeState(
      dir,
      _ShipState(
        lastShippedEventId: toEventId,
        lastShippedAtMs: DateTime.now().millisecondsSinceEpoch,
        shipCount: state.shipCount + 1,
      ),
    );

    final String msg;
    if (posted) {
      msg = 'shipped ${rows.length} event(s) to the collector + audit log';
    } else if (_endpoint.isEmpty) {
      msg = 'recorded ${rows.length} event(s) to the audit log '
          '(collector not configured; audit-log-only mode)';
    } else if (!auditWritten) {
      msg = 'collector POST and audit write both failed; watermark advanced';
    } else {
      msg = 'audit log written; collector POST failed (will resume next ship)';
    }
    return UsageShipResult(
      shipped: true,
      events: rows.length,
      fromEventId: state.lastShippedEventId,
      toEventId: toEventId,
      posted: posted,
      payloadJson: jsonStr,
      message: msg,
    );
  }

  static Map<String, String>? _envOverride;

  /// Test seam: pins the env the opt-out check reads, so ship tests are not
  /// at the mercy of the host shell's `FLUTTER_NETWORK_MCP_NO_*` vars. Pass
  /// null to revert to the real process environment.
  static set envForTest(Map<String, String>? env) => _envOverride = env;

  static String? _endpointOverride;

  /// Test seam: overrides the collector endpoint so tests never POST to the
  /// real (baked) collector. Set to `''` to force audit-log-only. Pass null
  /// to revert to the compiled-in [kCollectorEndpoint].
  static set endpointForTest(String? endpoint) => _endpointOverride = endpoint;

  static String get _endpoint => _endpointOverride ?? kCollectorEndpoint;

  static bool _optedOut() {
    final env = _envOverride ?? io.Platform.environment;
    return telemetryDisabled(env) ||
        truthyEnv(env['FLUTTER_NETWORK_MCP_NO_USAGE']);
  }

  static _ShipState _readState(String dataDir) {
    try {
      final f = io.File(p.join(dataDir, stateFileName));
      if (!f.existsSync()) return const _ShipState();
      final m = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
      return _ShipState(
        lastShippedEventId: (m['lastShippedEventId'] as int?) ?? 0,
        lastShippedAtMs: m['lastShippedAtMs'] as int?,
        shipCount: (m['shipCount'] as int?) ?? 0,
      );
    } catch (_) {
      return const _ShipState();
    }
  }

  static void _writeState(String dataDir, _ShipState s) {
    final f = io.File(p.join(dataDir, stateFileName));
    if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
    f.writeAsStringSync(
      jsonEncode({
        'lastShippedEventId': s.lastShippedEventId,
        'lastShippedAtMs': s.lastShippedAtMs,
        'shipCount': s.shipCount,
      }),
      flush: true,
    );
  }
}

/// Builds the privacy-safe rollup payload from raw events (each carrying
/// `id`, `ts_ms`, `correlation_id`, `tool`, `outcome`, `duration_ms`,
/// `result_bytes`). Visible for testing.
///
/// What is IN: package version + commit + AOT flag, host OS + Dart version,
/// the HMAC `machineHash` (same value as crash telemetry, for cross-payload
/// dedupe), the event-id + timestamp window, and the [summarizeUsage]
/// aggregate (per-tool counts / outcome rates / p50-p95 latency / avg
/// result size, plus the tool-to-next-tool transition graph).
///
/// What is NOT in: arg values, URLs, hosts, bodies, log text, raw
/// correlation ids, or any per-event row. The aggregate is the unit.
Map<String, Object?> buildUsagePayload({
  required List<Map<String, Object?>> rows,
  required String dataDir,
}) {
  final stats = summarizeUsage(rows, topTransitions: 100);

  var firstMs = 0;
  var lastMs = 0;
  var toEventId = 0;
  var seen = false;
  for (final r in rows) {
    final ts = (r['ts_ms'] as int?) ?? 0;
    final id = (r['id'] as int?) ?? 0;
    if (!seen) {
      firstMs = ts;
      lastMs = ts;
      seen = true;
    } else {
      if (ts < firstMs) firstMs = ts;
      if (ts > lastMs) lastMs = ts;
    }
    if (id > toEventId) toEventId = id;
  }

  final commit = shortCommit();
  return <String, Object?>{
    'kind': 'usage_rollup',
    'version': packageVersion,
    if (commit != null) 'commit': commit,
    'isAot': isAotBuild,
    'os': osDescriptor(),
    'dart': dartVersion(),
    'machineHash': machineHash(dataDir),
    'window': {
      'firstEventMs': firstMs,
      'lastEventMs': lastMs,
      'toEventId': toEventId,
    },
    'totalEvents': stats['totalEvents'],
    'totalTurns': stats['totalTurns'],
    'tools': stats['tools'],
    'transitions': stats['transitions'],
    if (stats['selfCorrection'] != null) 'selfCorrection': stats['selfCorrection'],
    'reportedAt': DateTime.now().toUtc().toIso8601String(),
  };
}

/// Outcome of a [UsageReporter.ship] call.
class UsageShipResult {
  const UsageShipResult({
    required this.shipped,
    required this.message,
    this.events = 0,
    this.fromEventId = 0,
    this.toEventId = 0,
    this.posted = false,
    this.dryRun = false,
    this.payloadJson,
  });

  /// True when a rollup was written (audit log advanced, watermark moved).
  /// False for opt-out, no-new-events, dry-run, or a hard failure.
  final bool shipped;
  final String message;
  final int events;
  final int fromEventId;
  final int toEventId;

  /// True when the collector POST returned a 2xx. Always false in
  /// audit-log-only mode (empty [kCollectorEndpoint]).
  final bool posted;
  final bool dryRun;

  /// The exact rollup JSON, for `--json` / inspection. Null when there was
  /// nothing to build.
  final String? payloadJson;
}

class _ShipState {
  const _ShipState({
    this.lastShippedEventId = 0,
    this.lastShippedAtMs,
    this.shipCount = 0,
  });

  final int lastShippedEventId;
  final int? lastShippedAtMs;
  final int shipCount;
}
