import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../storage/captures_db.dart';
import 'result.dart';

final alertsDrainTool = Tool(
  name: 'alerts_drain',
  description:
      'Returns pending alerts (newest-first) and marks them as drained. '
      'Call this at the start of an investigation to see everything that has '
      'gone wrong since you last drained. Defaults to the live session; pass '
      'sessionId to drain history.',
  inputSchema: Schema.object(
    properties: {
      'sessionId': Schema.int(description: 'Restrict to a session. Default: live.'),
      'severityMin': Schema.string(
        description: 'info | warning | error | critical. Default: any.',
      ),
      'limit': Schema.int(description: 'Max alerts (default 50, hard cap 200).'),
    },
  ),
);

FutureOr<CallToolResult> alertsDrain(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final session = Session.instance;
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
    return jsonResult({
      'sessionId': sessionId,
      'count': rows.length,
      'alerts': [for (final r in rows) _toAlertJson(r)],
    });
  } catch (e) {
    return errorResult('alerts_drain failed: $e');
  }
}

Map<String, Object?> _toAlertJson(Map<String, Object?> r) {
  return {
    'id': r['id'],
    'sessionId': r['session_id'],
    'tsMs': r['ts_ms'],
    'severity': r['severity'],
    'kind': r['kind'],
    'title': r['title'],
    'detail': r['detail'],
    'sourceKind': r['source_kind'],
    'sourceId': r['source_id'],
  };
}
