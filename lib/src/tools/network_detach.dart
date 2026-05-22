import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../storage/captures_db.dart';
import 'result.dart';

final networkDetachTool = Tool(
  name: 'network_detach',
  description:
      'Closes DTD + VM service connections, stops the capture writer, and '
      'marks the live session as ended in the DB. Captured rows remain '
      'queryable via session_list / session_open. Idempotent — safe to call '
      'when not attached.',
  inputSchema: Schema.object(properties: {}),
);

FutureOr<CallToolResult> networkDetach(CallToolRequest request) async {
  final session = Session.instance;
  final wasAttached = session.isAttached;
  final endedSession = session.liveSessionId;
  final appName = session.attachedAppName;

  // Gather counts BEFORE detach so the summary can report them.
  int httpCount = 0;
  int logCount = 0;
  int alertCount = 0;
  if (endedSession != null) {
    try {
      final dao = CapturesDao();
      final r = dao.rawSelect(
        'SELECT '
        '(SELECT COUNT(*) FROM http_requests WHERE session_id=$endedSession) AS http_n, '
        '(SELECT COUNT(*) FROM log_records WHERE session_id=$endedSession) AS log_n, '
        '(SELECT COUNT(*) FROM alerts WHERE session_id=$endedSession) AS alert_n',
      );
      if (r.isNotEmpty) {
        httpCount = (r.first['http_n'] as int?) ?? 0;
        logCount = (r.first['log_n'] as int?) ?? 0;
        alertCount = (r.first['alert_n'] as int?) ?? 0;
      }
      dao.endSession(endedSession);
    } catch (_) {/* DB may already be closed */}
  }

  await session.detach();

  final summary = wasAttached
      ? 'Detached from ${appName ?? "app"}. Session $endedSession ended — captured $httpCount http, $logCount log(s), $alertCount alert(s). All queryable via session_open id:$endedSession.'
      : 'No-op: was not attached.';

  return jsonResult({
    'detached': true,
    'summary': summary,
    'wasAttached': wasAttached,
    if (endedSession != null) ...{
      'endedSessionId': endedSession,
      'captured': {'http': httpCount, 'logs': logCount, 'alerts': alertCount},
    },
    'nextSteps': wasAttached
        ? [
            if (endedSession != null) 'session_open id:$endedSession — view what was captured',
            'session_list — see all sessions including this one',
            'network_attach — reconnect to capture more (or a different app)',
          ]
        : const [
            'network_status — see what apps are reachable',
            'network_attach — connect to a live app',
            'session_list — view past sessions',
          ],
  });
}
