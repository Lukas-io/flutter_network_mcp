import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../storage/captures_db.dart';
import 'result.dart';

final alertsClearTool = Tool(
  name: 'alerts_clear',
  description:
      'Permanently DELETES alert rows from the DB. Default is the safe path: '
      'only already-drained alerts (`drainedOnly:true`). To also remove '
      'undrained (unread) alerts you must explicitly pass '
      '`drainedOnly:false` AND `confirm:true` so they cannot be lost by '
      'accident.',
  inputSchema: Schema.object(
    properties: {
      'sessionId': Schema.int(description: 'Restrict to a session id (default: all sessions).'),
      'severityMin': Schema.string(
        description: '"info" | "warning" | "error" | "critical".',
      ),
      'drainedOnly': Schema.bool(
        description: 'Only delete alerts already returned by alerts_drain. Default true.',
      ),
      'confirm': Schema.bool(
        description: 'Required when drainedOnly:false (deleting undrained alerts is destructive).',
      ),
    },
  ),
);

FutureOr<CallToolResult> alertsClear(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final sessionId = args['sessionId'] as int?;
  final severityMin = args['severityMin'] as String?;
  final drainedOnly = (args['drainedOnly'] as bool?) ?? true;
  final confirm = (args['confirm'] as bool?) ?? false;

  if (!drainedOnly && !confirm) {
    return errorResult(
      'Deleting undrained alerts requires `confirm:true`. They have not been read yet.',
      extra: {
        'sessionId': sessionId,
        'drainedOnly': false,
        'nextSteps': const [
          'alerts_drain — read undrained alerts first',
          'alerts_clear drainedOnly:false confirm:true — to delete anyway',
        ],
      },
    );
  }

  try {
    final dao = CapturesDao();
    final deleted = dao.clearAlerts(
      sessionId: sessionId,
      severityMin: severityMin,
      drainedOnly: drainedOnly,
    );
    final remaining = dao.pendingAlertCount(
      sessionId: sessionId,
      severityMin: severityMin,
    );
    final scopeBits = <String>[];
    if (sessionId != null) scopeBits.add('session $sessionId');
    if (severityMin != null) scopeBits.add('severity≥$severityMin');
    if (drainedOnly) scopeBits.add('drained only');
    final scope = scopeBits.isEmpty ? 'all sessions' : scopeBits.join(', ');

    final summary = deleted == 0
        ? 'No alerts matched filters ($scope) — nothing deleted.'
        : 'Deleted $deleted alert(s) from $scope. $remaining undrained still pending in scope.';

    final warnings = <String>[];
    if (!drainedOnly) {
      warnings.add('Undrained alerts were deleted — they are gone permanently.');
    }
    if (remaining > 0) {
      warnings.add('$remaining undrained alert(s) still pending in scope. Call alerts_drain to see them.');
    }

    return jsonResult({
      'summary': summary,
      'deleted': deleted,
      'remainingPending': remaining,
      'sessionId': sessionId,
      'severityMin': severityMin,
      'drainedOnly': drainedOnly,
      if (warnings.isNotEmpty) 'warnings': warnings,
      'nextSteps': [
        if (remaining > 0) 'alerts_drain — handle the still-pending alert(s)',
        if (remaining == 0) 'alerts_peek — confirm clean state',
        'db_stats — see DB size impact',
      ],
    });
  } catch (e) {
    return errorResult('alerts_clear failed: $e', extra: {
      'sessionId': sessionId,
      'nextSteps': const [
        'session_list — confirm sessionId is valid',
      ],
    });
  }
}
