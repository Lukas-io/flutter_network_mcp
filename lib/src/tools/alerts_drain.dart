import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../config/capabilities.dart';
import '../storage/captures_db.dart';
import '../util/scope.dart';
import 'error_kind.dart';
import 'result.dart';

final alertsDrainTool = Tool(
  name: 'alerts_drain',
  description:
      'Returns pending alerts (newest-first) AND marks them drained. The '
      '"what is wrong?" first call. Scope auto-resolves to the sole attached '
      'session.',
  inputSchema: Schema.object(
    properties: {
      'sessionId': Schema.int(
        description:
            'Session to read from. Omit to auto-resolve (the sole attached '
            'session, or the one you opened).',
      ),
      'appNameContains': Schema.string(
        description: 'Pick the session by app-name substring instead of sessionId.',
      ),
      'severityMin': Schema.string(
        description: '"info" | "warning" | "error" | "critical". Default: any.',
      ),
      'limit': Schema.int(
        description: 'Max alerts (default 50, cap 200).',
      ),
    },
  ),
);

FutureOr<CallToolResult> alertsDrain(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final caps = CapabilityConfig.instance;
  final (scope, scopeErr) = resolveScope(args);
  if (scopeErr != null) return scopeErr;
  scope!;
  final sessionId = scope.sessionId;
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
      scope: scope,
      severityMin: severityMin,
      rows: rows,
      caps: caps,
    ));
  } catch (e) {
    return errorResult('alerts_drain failed: $e', kind: ErrorKind.internal, extra: {
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
  required String action,
  required Scope scope,
  required String? severityMin,
  required List<Map<String, Object?>> rows,
  required CapabilityConfig caps,
}) {
  final sessionId = scope.sessionId;
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
  final sessionDesc = ' session $sessionId'
      '${scope.appName != null ? " (${scope.appName})" : ""}';
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

  final dao = CapturesDao();
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
        'occurrenceCount': (r['occurrence_count'] as int?) ?? 1,
        'firstSeenMs': r['ts_ms'],
        'lastSeenMs': r['last_seen_ms'] ?? r['ts_ms'],
        if (r['last_source_id'] != null) 'lastSourceId': r['last_source_id'],
        if (r['signature'] != null) 'signature': r['signature'],
        if (r['signature'] != null)
          ..._priorOccurrencesIfAny(
            dao,
            signature: r['signature'] as String,
            currentSessionId: r['session_id'] as int,
          ),
      },
  ];

  return {
    'scope': scope.toBlock(),
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

/// Returns a single-entry map keyed by `priorOccurrences` (so it spreads
/// cleanly into the alert literal via `...`) when 1+ prior occurrence of
/// [signature] exists in another session. Empty map otherwise — read-and-
/// query errors stay silent so a transient DB hiccup doesn't break the
/// drain response.
Map<String, Object?> _priorOccurrencesIfAny(
  CapturesDao dao, {
  required String signature,
  required int currentSessionId,
}) {
  final List<Map<String, Object?>> prior;
  try {
    prior = dao.priorOccurrencesForSignature(
      signature: signature,
      excludeSessionId: currentSessionId,
    );
  } catch (_) {
    return const {};
  }
  if (prior.isEmpty) return const {};
  return {
    'priorOccurrences': [
      for (final p in prior)
        {
          'sessionId': p['session_id'],
          'startedAtMs': p['started_at'],
          if (p['app_name'] != null) 'appName': p['app_name'],
          if (p['note'] != null) 'note': p['note'],
        },
    ],
  };
}
