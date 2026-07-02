import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../config/capabilities.dart';
import '../storage/captures_db.dart';
import '../util/scope.dart';
import '../util/guidance.dart';
import 'error_kind.dart';
import 'network_summarize.dart' show summarizeRequests;
import 'result.dart';

final networkReportTool = Tool(
  name: 'network_report',
  description:
      'One-call session health triage: the worst error endpoints, the slowest '
      'endpoints, pending alerts, and a recommended next action. Insight, not '
      'raw rows, the orientation call to run after network_status.',
  inputSchema: Schema.object(
    properties: {
      'sessionId': Schema.int(
        description: 'Session to read. Omit to auto-resolve.',
      ),
      'appNameContains': Schema.string(
        description: 'Pick the session by app-name substring.',
      ),
      'sinceMs': Schema.int(
        description: 'Window in ms. Default 0 (whole session).',
      ),
    },
  ),
);

const int _kRawRowsCap = 10000;

FutureOr<CallToolResult> networkReport(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final (scope, scopeErr) = resolveScope(args);
  if (scopeErr != null) return scopeErr;
  scope!;
  final sid = scope.sessionId;
  final caps = CapabilityConfig.instance;
  final sinceMs = (args['sinceMs'] as int?) ?? 0;
  final nowUs = DateTime.now().microsecondsSinceEpoch;
  final sinceUs = sinceMs <= 0 ? null : nowUs - (sinceMs * 1000);

  final dao = CapturesDao();
  List<Map<String, Object?>> endpoints;
  try {
    endpoints = summarizeRequests(
      dao.queryHttpRequests(sessionId: sid, sinceUs: sinceUs, limit: _kRawRowsCap),
      minCount: 1,
    );
  } catch (e) {
    return errorResult('network_report query failed: $e',
        kind: ErrorKind.internal,
        extra: const {
          'nextSteps': [
            'network_status — confirm the session is reachable',
            'network_summarize — try the raw digest',
          ],
        });
  }

  final totalRequests = endpoints.fold<int>(
      0, (s, e) => s + ((e['count'] as int?) ?? 0));

  num impact(Map<String, Object?> e) =>
      (e['errorRate'] as num) * (e['count'] as int);
  final errorHotspots = [
    for (final e in endpoints)
      if ((e['errorRate'] as num) > 0) e,
  ]..sort((a, b) => impact(b).compareTo(impact(a)));

  final slowest = [...endpoints]..sort((a, b) =>
      ((b['p95LatencyMs'] as int?) ?? 0).compareTo((a['p95LatencyMs'] as int?) ?? 0));

  Map<String, Object?> trim(Map<String, Object?> e) => {
        'endpoint': e['endpoint'],
        'count': e['count'],
        'errorRate': e['errorRate'],
        'p95LatencyMs': e['p95LatencyMs'],
      };

  final topErrors = errorHotspots.take(3).map(trim).toList();
  final topSlow = slowest
      .where((e) => (e['p95LatencyMs'] as int?) != null)
      .take(3)
      .map(trim)
      .toList();

  var pendingAlerts = 0;
  if (caps.isEnabled(Category.alerts)) {
    try {
      pendingAlerts = dao.pendingAlertCount(sessionId: sid);
    } catch (_) {/* best-effort */}
  }

  final String headline;
  final List<String> nextSteps;
  if (endpoints.isEmpty) {
    final state = SessionStateView.of(sid);
    headline = state.canGenerateTraffic
        ? 'No HTTP captured for session $sid yet.'
        : 'No HTTP captured in session $sid (its capture is complete).';
    nextSteps = [
      emptyCaptureHint(state, reRun: 'network_report'),
      if (state.canGenerateTraffic)
        'network_status — confirm the session is attached and capturing',
    ];
  } else if (topErrors.isNotEmpty) {
    final worst = topErrors.first;
    headline = 'Top problem: ${worst['endpoint']} is failing '
        '${((worst['errorRate'] as num) * 100).round()}% of '
        '${worst['count']} call(s).';
    nextSteps = [
      // D1: a host-wide search matches everything on the host; route to the
      // error rows directly instead.
      'network_list statusMin:400 hostContains:"${_hostOf(worst)}" — list the failing requests, then network_get one',
      if (caps.isEnabled(Category.alerts) && pendingAlerts > 0)
        'alerts_drain — $pendingAlerts pending alert(s)',
      'network_drift hostContains:"${_hostOf(worst)}" — check if the response shape changed',
    ];
  } else if (topSlow.isNotEmpty &&
      ((topSlow.first['p95LatencyMs'] as int?) ?? 0) > 1000) {
    final s = topSlow.first;
    headline = 'No errors; slowest endpoint ${s['endpoint']} at '
        '${s['p95LatencyMs']}ms p95.';
    nextSteps = [
      'network_summarize — full latency breakdown',
      if (pendingAlerts > 0) 'alerts_drain — $pendingAlerts pending alert(s)',
    ];
  } else {
    headline = 'Healthy: $totalRequests request(s) across ${endpoints.length} '
        'endpoint(s), no error hotspots.';
    nextSteps = [
      if (pendingAlerts > 0)
        'alerts_drain — $pendingAlerts pending alert(s)'
      else
        'network_summarize — endpoint-by-endpoint detail',
    ];
  }

  return jsonResult({
    'summary': headline,
    'sessionId': sid,
    'totalRequests': totalRequests,
    'distinctEndpoints': endpoints.length,
    'errorHotspots': topErrors,
    'slowestEndpoints': topSlow,
    'nextSteps': nextSteps,
  }, scopeSessionId: sid);
}

String _hostOf(Map<String, Object?> endpoint) {
  final ep = (endpoint['endpoint'] as String?) ?? '';
  final parts = ep.split(' ');
  if (parts.length < 2) return '';
  final hostPath = parts[1];
  final slash = hostPath.indexOf('/');
  return slash <= 0 ? hostPath : hostPath.substring(0, slash);
}
