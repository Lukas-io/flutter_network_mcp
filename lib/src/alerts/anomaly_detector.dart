import 'dart:async';
import 'dart:io' as io;

import '../state/session.dart';
import '../storage/captures_db.dart';
import '../tools/network_summarize.dart';
import 'alert_rules.dart';
import 'signature.dart';

/// Baseline-relative HTTP anomaly detection.
///
/// Fires when the **current** behavior of an endpoint diverges from its
/// established **baseline** — catches regressions a static threshold
/// (`http_slow` at a fixed 3000ms) would miss for endpoints that are
/// normally either much faster or much slower.
///
/// **Latency anomaly** (`http_anomaly` kind, warning severity):
/// - Current window: last [currentWindow].
/// - Baseline window: last [baselineWindow] ending [currentWindow] ago.
/// - Per endpoint: at least [minRequests] in EACH window.
/// - Trigger: current p95 > [latencyMultiplier] × baseline p95.
///
/// **Error-rate anomaly** (`http_anomaly_errors` kind, error severity):
/// - Same windowing.
/// - Trigger: current error rate > [errorRateMultiplier] × baseline AND
///   current error rate > [errorRateAbsFloor].
///
/// Alerts dedupe through the 0.6.3 signature pipeline — burst of 50
/// anomaly events on the same endpoint collapses to one row with
/// `occurrenceCount` rolling up.
///
/// **Lifecycle:** singleton, lazily started by `network_attach` (only
/// when at least one session is attached) and stopped by
/// `network_detach` when the registry hits zero. No work done while no
/// sessions are attached.
class AnomalyDetector {
  AnomalyDetector._();

  static final AnomalyDetector instance = AnomalyDetector._();

  /// Polling interval — same period as the alert tick.
  static const Duration tickInterval = Duration(seconds: 30);

  /// Current behavior window.
  static const Duration currentWindow = Duration(seconds: 30);

  /// Baseline window (ending where the current window starts).
  static const Duration baselineWindow = Duration(minutes: 5);

  static const int minRequests = 10;
  static const double latencyMultiplier = 2.0;
  static const double errorRateMultiplier = 5.0;
  static const double errorRateAbsFloor = 0.10;

  Timer? _timer;
  bool _ticking = false;

  bool get isRunning => _timer != null;

  /// Called from `network_attach` success path. No-op when already
  /// running or when [AlertRules.anomalyEnabled] is false.
  void startIfNeeded() {
    if (_timer != null) return;
    if (!AlertRules.instance.anomalyEnabled) return;
    _timer = Timer.periodic(tickInterval, (_) => _tick());
  }

  /// Called from `network_detach` when `registry.attachedCount == 0`.
  /// Idempotent.
  void stopIfNoSessions() {
    if (SessionRegistry.instance.attachedCount > 0) return;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    if (_ticking) return;
    _ticking = true;
    try {
      final nowUs = DateTime.now().microsecondsSinceEpoch;
      for (final attached in SessionRegistry.instance.attached.values) {
        try {
          await _checkSession(attached.id, nowUs);
        } catch (e, st) {
          io.stderr.writeln(
            'flutter_network_mcp: anomaly detector tick crashed for session '
            '${attached.id} ($e). Continuing other sessions.\n$st',
          );
        }
      }
    } finally {
      _ticking = false;
    }
  }

  /// Visible for testing — runs one detection pass against the provided
  /// row set. Returns the list of `(kind, title, detail)` tuples that
  /// would be inserted as alerts. Pure function, no DB writes.
  List<DetectedAnomaly> detectAnomalies({
    required List<Map<String, Object?>> currentRows,
    required List<Map<String, Object?>> baselineRows,
  }) {
    final currentBuckets =
        summarizeRequests(currentRows, minCount: minRequests);
    final baselineBuckets =
        summarizeRequests(baselineRows, minCount: minRequests);
    final baselineByKey = <String, Map<String, Object?>>{
      for (final b in baselineBuckets)
        '${b['method']}|${b['host']}|${b['pathTemplate']}': b,
    };

    final out = <DetectedAnomaly>[];
    for (final c in currentBuckets) {
      final key = '${c['method']}|${c['host']}|${c['pathTemplate']}';
      final baseline = baselineByKey[key];
      if (baseline == null) continue;

      final currentP95 = c['p95LatencyMs'] as int?;
      final baselineP95 = baseline['p95LatencyMs'] as int?;
      if (currentP95 != null &&
          baselineP95 != null &&
          baselineP95 > 0 &&
          currentP95 > latencyMultiplier * baselineP95) {
        final mult = (currentP95 / baselineP95).toStringAsFixed(1);
        out.add(DetectedAnomaly(
          kind: 'http_anomaly',
          severity: 'warning',
          title: '${c['endpoint']} p95 ${currentP95}ms vs baseline '
              '${baselineP95}ms (${mult}x)',
          detail:
              'Current 30s p95 (${currentP95}ms over ${c['count']} requests) '
              'is ${mult}x the 5min baseline (${baselineP95}ms over '
              '${baseline['count']} requests). Threshold: '
              '${latencyMultiplier}x.',
          sourceId: 'anomaly:${c['endpoint']}',
        ));
      }

      final currentErr = (c['errorRate'] as num).toDouble();
      final baselineErr = (baseline['errorRate'] as num).toDouble();
      if (currentErr > errorRateAbsFloor &&
          baselineErr > 0 &&
          currentErr > errorRateMultiplier * baselineErr) {
        final mult = (currentErr / baselineErr).toStringAsFixed(1);
        out.add(DetectedAnomaly(
          kind: 'http_anomaly_errors',
          severity: 'error',
          title: '${c['endpoint']} error rate '
              '${(currentErr * 100).toStringAsFixed(1)}% vs baseline '
              '${(baselineErr * 100).toStringAsFixed(1)}% (${mult}x)',
          detail:
              'Current 30s error rate ${(currentErr * 100).toStringAsFixed(1)}% '
              'across ${c['count']} requests; 5min baseline '
              '${(baselineErr * 100).toStringAsFixed(1)}% across '
              '${baseline['count']} requests. Floor: '
              '${(errorRateAbsFloor * 100).toStringAsFixed(0)}%; multiplier: '
              '${errorRateMultiplier}x.',
          sourceId: 'anomaly:errs:${c['endpoint']}',
        ));
      }
    }
    return out;
  }

  Future<void> _checkSession(int sessionId, int nowUs) async {
    final currentStartUs = nowUs - currentWindow.inMicroseconds;
    final baselineStartUs = nowUs -
        currentWindow.inMicroseconds -
        baselineWindow.inMicroseconds;

    final dao = CapturesDao();
    final rows = dao.queryHttpRequests(
      sessionId: sessionId,
      sinceUs: baselineStartUs,
      limit: 10000,
    );
    final currentRows = <Map<String, Object?>>[];
    final baselineRows = <Map<String, Object?>>[];
    for (final r in rows) {
      final startUs = r['start_us'] as int?;
      if (startUs == null) continue;
      if (startUs >= currentStartUs) {
        currentRows.add(r);
      } else {
        baselineRows.add(r);
      }
    }

    final anomalies = detectAnomalies(
      currentRows: currentRows,
      baselineRows: baselineRows,
    );
    for (final a in anomalies) {
      dao.insertAlert(
        sessionId: sessionId,
        severity: a.severity,
        kind: a.kind,
        title: a.title,
        signature: computeAlertSignature(kind: a.kind, title: a.title),
        detail: a.detail,
        sourceKind: 'http',
        sourceId: '${a.sourceId}:$sessionId',
      );
    }
  }
}

class DetectedAnomaly {
  const DetectedAnomaly({
    required this.kind,
    required this.severity,
    required this.title,
    required this.detail,
    required this.sourceId,
  });

  final String kind;
  final String severity;
  final String title;
  final String detail;
  final String sourceId;
}
