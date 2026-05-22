import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../config/capabilities.dart';
import '../state/session.dart';
import '../storage/captures_db.dart';
import 'alerts_drain.dart' show buildAlertsResponse;
import 'result.dart';

final alertsPeekTool = Tool(
  name: 'alerts_peek',
  description:
      'Returns pending alerts WITHOUT marking them as drained — read-only '
      'sibling of alerts_drain. Use to triage what is waiting before '
      'committing. Same args and response shape.',
  inputSchema: Schema.object(
    properties: {
      'sessionId': Schema.int(
        description: 'Restrict to a session id. Default: current session (live or viewed).',
      ),
      'severityMin': Schema.string(
        description: '"info" | "warning" | "error" | "critical". Default: any.',
      ),
      'limit': Schema.int(
        description: 'Max alerts returned (default 20, hard cap 200). Newest-first.',
      ),
    },
  ),
);

FutureOr<CallToolResult> alertsPeek(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final session = Session.instance;
  final caps = CapabilityConfig.instance;
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
    return jsonResult(buildAlertsResponse(
      action: 'peek',
      sessionId: sessionId,
      severityMin: severityMin,
      rows: rows,
      caps: caps,
    ));
  } catch (e) {
    return errorResult('alerts_peek failed: $e', extra: {
      'sessionId': sessionId,
      'nextSteps': const [
        'network_status — confirm DB is open',
        'session_list — check the session id is valid',
      ],
    });
  }
}
