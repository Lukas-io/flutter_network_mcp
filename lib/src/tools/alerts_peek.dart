import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../storage/captures_db.dart';
import 'result.dart';

final alertsPeekTool = Tool(
  name: 'alerts_peek',
  description:
      'Returns pending alerts WITHOUT marking them as drained. Use this when '
      'you want to see what is waiting without committing to "I have read '
      'this". Identical args + output to alerts_drain.',
  inputSchema: Schema.object(
    properties: {
      'sessionId': Schema.int(description: 'Restrict to a session. Default: live.'),
      'severityMin': Schema.string(
        description: 'info | warning | error | critical. Default: any.',
      ),
      'limit': Schema.int(description: 'Max alerts (default 20, hard cap 200).'),
    },
  ),
);

FutureOr<CallToolResult> alertsPeek(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final session = Session.instance;
  final sessionId = (args['sessionId'] as int?) ?? session.effectiveSessionId;
  final severityMin = args['severityMin'] as String?;
  final limitRaw = (args['limit'] as int?) ?? 20;
  final limit = limitRaw <= 0 ? 20 : (limitRaw > 200 ? 200 : limitRaw);

  try {
    final rows = CapturesDao().peekAlerts(
      sessionId: sessionId,
      severityMin: severityMin,
      limit: limit,
    );
    return jsonResult({
      'sessionId': sessionId,
      'count': rows.length,
      'alerts': [
        for (final r in rows)
          {
            'id': r['id'],
            'sessionId': r['session_id'],
            'tsMs': r['ts_ms'],
            'severity': r['severity'],
            'kind': r['kind'],
            'title': r['title'],
            'detail': r['detail'],
            'sourceKind': r['source_kind'],
            'sourceId': r['source_id'],
          },
      ],
    });
  } catch (e) {
    return errorResult('alerts_peek failed: $e');
  }
}
