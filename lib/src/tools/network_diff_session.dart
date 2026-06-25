import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../storage/captures_db.dart';
import '../util/scope.dart';
import 'error_kind.dart';
import 'network_summarize.dart' show summarizeRequests;
import 'result.dart';

final networkDiffSessionTool = Tool(
  name: 'network_diff_session',
  description:
      'What changed between two runs: diffs the current session against a '
      'baseline session by endpoint (method+host+pathTemplate). Returns '
      'newEndpoints, goneEndpoints, and changed (error-rate / p95 shifts). '
      'Answers "what is different about today\'s run".',
  inputSchema: Schema.object(
    properties: {
      'baselineSessionId': Schema.int(
        description: 'The OLDER run to compare against (id from session_list).',
      ),
      'sessionId': Schema.int(
        description:
            'The NEWER/current session. Omit to auto-resolve (the live '
            'attached session, or the one you opened).',
      ),
      'appNameContains': Schema.string(
        description: 'Pick the current session by app-name substring.',
      ),
      'minCount': Schema.int(
        description:
            'Ignore endpoints with fewer than this many requests on each '
            'side. Default 1.',
      ),
    },
    required: ['baselineSessionId'],
  ),
);

const int _kRawRowsCap = 10000;

FutureOr<CallToolResult> networkDiffSession(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final baselineId = args['baselineSessionId'] as int?;
  if (baselineId == null) {
    return errorResult('Missing required arg `baselineSessionId`.',
        kind: ErrorKind.badArgument,
        extra: const {
          'nextSteps': [
            'session_list — pick a past session id to compare against',
          ],
        });
  }
  final (scope, scopeErr) = resolveScope(args);
  if (scopeErr != null) return scopeErr;
  scope!;
  final currentId = scope.sessionId;
  if (currentId == baselineId) {
    return errorResult(
        'baselineSessionId equals the current session ($currentId); pick a '
        'different baseline.',
        kind: ErrorKind.badArgument,
        extra: const {
          'nextSteps': ['session_list — choose a different past session'],
        });
  }
  final minCount = (args['minCount'] as int?) ?? 1;

  List<Map<String, Object?>> current;
  List<Map<String, Object?>> baseline;
  try {
    current = summarizeRequests(
      CapturesDao().queryHttpRequests(sessionId: currentId, limit: _kRawRowsCap),
      minCount: minCount,
    );
    baseline = summarizeRequests(
      CapturesDao().queryHttpRequests(sessionId: baselineId, limit: _kRawRowsCap),
      minCount: minCount,
    );
  } catch (e) {
    return errorResult('network_diff_session query failed: $e',
        kind: ErrorKind.internal,
        extra: {
          'nextSteps': const [
            'session_list — confirm both session ids exist',
            'network_summarize — check each session resolves on its own',
          ],
        });
  }

  final diff = diffEndpointSummaries(current, baseline);
  final newEndpoints = diff['newEndpoints'] as List;
  final goneEndpoints = diff['goneEndpoints'] as List;
  final changed = diff['changed'] as List;

  final summary =
      'Session $currentId vs baseline $baselineId: ${newEndpoints.length} new, '
      '${goneEndpoints.length} gone, ${changed.length} changed endpoint(s).';

  return jsonResult({
    'summary': summary,
    'currentSessionId': currentId,
    'baselineSessionId': baselineId,
    'newEndpoints': newEndpoints,
    'goneEndpoints': goneEndpoints,
    'changed': changed,
    'nextSteps': [
      if (changed.isNotEmpty)
        'network_summarize — drill into the current session endpoint stats',
      if (newEndpoints.isNotEmpty)
        'network_list hostContains:"..." — inspect a new endpoint live',
      'session_list — pick a different baseline session',
    ],
  }, scopeSessionId: currentId);
}

/// Diffs two lists of [summarizeRequests] endpoint buckets, keyed by
/// `endpoint`. Returns newEndpoints (in current only), goneEndpoints (in
/// baseline only), and changed (in both, with a material error-rate >= 0.1 or
/// a p95 latency regression of 2x either way). Visible for testing.
Map<String, Object?> diffEndpointSummaries(
  List<Map<String, Object?>> current,
  List<Map<String, Object?>> baseline,
) {
  Map<String, Map<String, Object?>> byEndpoint(List<Map<String, Object?>> eps) =>
      {for (final e in eps) e['endpoint'] as String: e};
  final cur = byEndpoint(current);
  final base = byEndpoint(baseline);

  final newEndpoints = [
    for (final k in cur.keys)
      if (!base.containsKey(k)) cur[k]!,
  ];
  final goneEndpoints = [
    for (final k in base.keys)
      if (!cur.containsKey(k)) base[k]!,
  ];

  final changed = <Map<String, Object?>>[];
  for (final entry in cur.entries) {
    final b = base[entry.key];
    if (b == null) continue;
    final a = entry.value;
    final aErr = (a['errorRate'] as num).toDouble();
    final bErr = (b['errorRate'] as num).toDouble();
    final aP95 = a['p95LatencyMs'] as int?;
    final bP95 = b['p95LatencyMs'] as int?;
    final errDelta = aErr - bErr;
    final p95Regressed = aP95 != null &&
        bP95 != null &&
        bP95 > 0 &&
        (aP95 > 2 * bP95 || bP95 > 2 * aP95);
    if (errDelta.abs() >= 0.1 || p95Regressed) {
      changed.add({
        'endpoint': entry.key,
        'errorRate': {
          'now': aErr,
          'baseline': bErr,
          'delta': double.parse(errDelta.toStringAsFixed(4)),
        },
        'p95LatencyMs': {'now': aP95, 'baseline': bP95},
        'count': {'now': a['count'], 'baseline': b['count']},
      });
    }
  }
  changed.sort((x, y) => ((y['errorRate'] as Map)['delta'] as num)
      .abs()
      .compareTo(((x['errorRate'] as Map)['delta'] as num).abs()));

  return {
    'newEndpoints': newEndpoints,
    'goneEndpoints': goneEndpoints,
    'changed': changed,
  };
}
