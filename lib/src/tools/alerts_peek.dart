import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../config/capabilities.dart';
import '../storage/captures_db.dart';
import '../util/scope.dart';
import 'alerts_drain.dart' show buildAlertsResponse;
import 'result.dart';

final alertsPeekTool = Tool(
  name: 'alerts_peek',
  description:
      'Returns pending alerts WITHOUT marking them as drained — read-only '
      'sibling of alerts_drain. Use to triage what is waiting before '
      'committing. Same scope resolution as alerts_drain.',
  inputSchema: Schema.object(
    properties: {
      'sessionId': Schema.int(
        description:
            'Which session to peek. Omit to auto-resolve: explicit view '
            '(session_open) → sole attached session → error if 2+ attached.',
      ),
      'appNameContains': Schema.string(
        description:
            'Alternative to sessionId — case-insensitive substring on a '
            'currently-attached app name.',
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
  final caps = CapabilityConfig.instance;
  final (scope, scopeErr) = resolveScope(args);
  if (scopeErr != null) return scopeErr;
  scope!;
  final sessionId = scope.sessionId;
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
      scope: scope,
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
