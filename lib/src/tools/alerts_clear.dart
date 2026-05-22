import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../storage/captures_db.dart';
import 'result.dart';

final alertsClearTool = Tool(
  name: 'alerts_clear',
  description:
      'Deletes alert rows from the DB. By default removes only already-drained '
      'alerts. Pass `drainedOnly:false` to clear undrained ones too.',
  inputSchema: Schema.object(
    properties: {
      'sessionId': Schema.int(description: 'Restrict to a session id.'),
      'severityMin': Schema.string(
        description: 'info | warning | error | critical.',
      ),
      'drainedOnly': Schema.bool(
        description: 'Only delete alerts that have already been drained (default true).',
      ),
    },
  ),
);

FutureOr<CallToolResult> alertsClear(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final sessionId = args['sessionId'] as int?;
  final severityMin = args['severityMin'] as String?;
  final drainedOnly = (args['drainedOnly'] as bool?) ?? true;

  try {
    final deleted = CapturesDao().clearAlerts(
      sessionId: sessionId,
      severityMin: severityMin,
      drainedOnly: drainedOnly,
    );
    return jsonResult({
      'deleted': deleted,
      'sessionId': sessionId,
      'severityMin': severityMin,
      'drainedOnly': drainedOnly,
    });
  } catch (e) {
    return errorResult('alerts_clear failed: $e');
  }
}
