import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../config/capabilities.dart';
import '../storage/captures_db.dart';
import '../util/scope.dart';
import 'alerts_drain.dart' show buildAlertsResponse;
import 'error_kind.dart';
import 'result.dart';

final alertsPeekTool = Tool(
  name: 'alerts_peek',
  description:
      'Pending alerts WITHOUT draining them (read-only sibling of '
      'alerts_drain). Use to triage before committing.',
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
        description: 'Max alerts (default 20, cap 200).',
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
    return errorResult('alerts_peek failed: $e', kind: ErrorKind.internal, extra: {
      'sessionId': sessionId,
      'nextSteps': const [
        'network_status — confirm DB is open',
        'session_list — check the session id is valid',
      ],
    });
  }
}
