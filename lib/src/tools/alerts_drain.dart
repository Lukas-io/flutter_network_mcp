import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../config/capabilities.dart';
import '../state/session.dart';
import '../storage/captures_db.dart';
import 'result.dart';

final alertsDrainTool = Tool(
  name: 'alerts_drain',
  description:
      'Returns pending alerts (newest-first) AND marks them as drained. The '
      'classic "what is wrong?" first call of an investigation. Defaults to '
      'the current session (live or viewed); pass `sessionId` to drain a '
      'specific session.',
  inputSchema: Schema.object(
    properties: {
      'sessionId': Schema.int(
        description: 'Restrict to a session id. Default: current session (live or viewed).',
      ),
      'severityMin': Schema.string(
        description: '"info" | "warning" | "error" | "critical". Default: any.',
      ),
      'limit': Schema.int(
        description: 'Max alerts returned (default 50, hard cap 200). Newest-first.',
      ),
    },
  ),
);

FutureOr<CallToolResult> alertsDrain(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final session = Session.instance;
  final caps = CapabilityConfig.instance;
  final sessionId = (args['sessionId'] as int?) ?? session.effectiveSessionId;
  final severityMin = args['severityMin'] as String?;
  final limitRaw = (args['limit'] as int?) ?? 50;
  final limit = limitRaw <= 0 ? 50 : (limitRaw > 200 ? 200 : limitRaw);

  try {
    final rows = CapturesDao().drainAlerts(
      sessionId: sessionId,
      severityMin: severityMin,
      limit: limit,
    );
    return jsonResult(buildAlertsResponse(
      action: 'drain',
      sessionId: sessionId,
      severityMin: severityMin,
      rows: rows,
      caps: caps,
    ));
  } catch (e) {
    return errorResult('alerts_drain failed: $e', extra: {
      'sessionId': sessionId,
      'nextSteps': const [
        'network_status — confirm DB is open',
        'alerts_peek — try the read-only sibling to isolate the issue',
      ],
    });
  }
}

/// Shared builder for drain + peek responses so the shape stays consistent.
Map<String, Object?> buildAlertsResponse({
  required String action, // 'drain' | 'peek'
  required int? sessionId,
  required String? severityMin,
  required List<Map<String, Object?>> rows,
  required CapabilityConfig caps,
}) {
  // Per-severity counts.
  int crit = 0, err = 0, warn = 0, info = 0;
  for (final r in rows) {
    switch ((r['severity'] as String?) ?? '') {
      case 'critical':
        crit++;
        break;
      case 'error':
        err++;
        break;
      case 'warning':
        warn++;
        break;
      case 'info':
        info++;
        break;
    }
  }
  final breakdown = <String>[];
  if (crit > 0) breakdown.add('$crit critical');
  if (err > 0) breakdown.add('$err error');
  if (warn > 0) breakdown.add('$warn warning');
  if (info > 0) breakdown.add('$info info');

  final actionVerb = action == 'drain' ? 'Drained' : 'Peeked at';
  final filterDesc = severityMin == null ? '' : ' (severityMin: $severityMin)';
  final sessionDesc = sessionId == null ? '' : ' session $sessionId';
  final summary = rows.isEmpty
      ? 'No pending alerts$sessionDesc$filterDesc.'
      : '$actionVerb ${rows.length} alert(s)$sessionDesc: ${breakdown.join(", ")}.';

  final firstHttp = rows.firstWhere(
    (r) => r['source_kind'] == 'http',
    orElse: () => const {},
  );
  final firstLog = rows.firstWhere(
    (r) => r['source_kind'] == 'log',
    orElse: () => const {},
  );

  final nextSteps = <String>[];
  if (rows.isEmpty) {
    if (action == 'drain') {
      nextSteps.add('Nothing to handle right now. Re-check with alerts_peek to avoid disturbing the queue.');
    } else {
      nextSteps.add('Nothing pending. Drive the app or wait for the detector to flag new events.');
    }
  } else {
    if (firstHttp.isNotEmpty && caps.isEnabled(Category.http)) {
      nextSteps.add(
        'network_get id:"${firstHttp['source_id']}" — full detail on the first HTTP-sourced alert',
      );
    }
    if (firstLog.isNotEmpty && caps.isEnabled(Category.logs)) {
      nextSteps.add(
        'logs_tail — context around the first log-sourced alert',
      );
    }
    if (action == 'peek') {
      nextSteps.add('alerts_drain — same data but marks them seen');
    }
    nextSteps.add('alerts_config — tune thresholds if these are noisy');
  }

  // Per-row null omission.
  final alerts = [
    for (final r in rows)
      {
        'id': r['id'],
        'sessionId': r['session_id'],
        'tsMs': r['ts_ms'],
        'severity': r['severity'],
        'kind': r['kind'],
        'title': r['title'],
        if (r['detail'] != null) 'detail': r['detail'],
        if (r['source_kind'] != null) 'sourceKind': r['source_kind'],
        if (r['source_id'] != null) 'sourceId': r['source_id'],
      },
  ];

  return {
    'sessionId': sessionId,
    'summary': summary,
    'count': rows.length,
    if (crit + err + warn + info > 0)
      'breakdown': {
        if (crit > 0) 'critical': crit,
        if (err > 0) 'error': err,
        if (warn > 0) 'warning': warn,
        if (info > 0) 'info': info,
      },
    'nextSteps': nextSteps,
    'alerts': alerts,
  };
}
