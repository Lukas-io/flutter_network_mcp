import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../config/capabilities.dart';
import '../state/session.dart';
import '../storage/captures_db.dart';
import 'error_kind.dart';
import 'result.dart';

final sessionDeleteTool = Tool(
  name: 'session_delete',
  description:
      'Permanently deletes a session and all its data (requests, bodies, '
      'sockets, logs, alerts, index). Cannot be undone; dry-run unless '
      'confirm:true. Refuses the live session (detach first).',
  inputSchema: Schema.object(
    properties: {
      'id': Schema.int(description: 'Session id to delete.'),
      'confirm': Schema.bool(
        description: 'Required true to delete; default false (dry-run).',
      ),
    },
    required: ['id'],
  ),
);

FutureOr<CallToolResult> sessionDelete(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final caps = CapabilityConfig.instance;
  final id = args['id'] as int?;
  final confirm = (args['confirm'] as bool?) ?? false;
  if (id == null) {
    return errorResult('Missing required arg `id`.', kind: ErrorKind.badArgument, extra: const {
      'nextSteps': ['session_list — find a session id'],
    });
  }

  final session = Session.instance;
  if (session.liveSessionId == id) {
    return errorResult('Cannot delete the live session — call network_detach first.', kind: ErrorKind.badArgument, extra: {
      'liveSessionId': id,
      'nextSteps': const [
        'network_detach — gracefully end the live session',
        'Then retry session_delete id:<n> confirm:true',
      ],
    });
  }

  final dao = CapturesDao();
  final row = dao.getSessionWithCounts(id);
  if (row == null) {
    return errorResult('Session $id not found.', kind: ErrorKind.notFound, extra: const {
      'nextSteps': ['session_list — see valid session ids'],
    });
  }

  final appName = row['app_name'] as String?;
  final httpCount = row['http_count'] ?? 0;
  final logCount = row['log_count'] ?? 0;
  final socketCount = row['socket_count'] ?? 0;
  final note = row['note'] as String?;

  if (!confirm) {
    return jsonResult({
      'summary': 'DRY-RUN — would delete session $id (${appName ?? "unnamed"}) and '
          '$httpCount http, $logCount log(s), $socketCount socket(s). Cannot be undone.',
      'dryRun': true,
      'sessionId': id,
      if (appName != null) 'appName': appName,
      'startedMs': row['started_at'],
      if (row['ended_at'] != null) 'endedMs': row['ended_at'],
      if (note != null) 'note': note,
      'counts': {'http': httpCount, 'sockets': socketCount, 'logs': logCount},
      'nextSteps': [
        if (caps.isEnabled(Category.sessions))
          'session_export id:$id format:"har" outPath:"..." — back up before deleting',
        'session_delete id:$id confirm:true — proceed with the delete',
      ],
    });
  }

  if (session.viewedSessionId == id) {
    session.viewedSessionId = null;
  }
  final deleted = dao.deleteSession(id);

  return jsonResult({
    'summary': 'Deleted session $id (${appName ?? "unnamed"}) — '
        '$httpCount http, $logCount log(s), $socketCount socket(s) removed.',
    'deleted': deleted,
    'sessionId': id,
    if (appName != null) 'appName': appName,
    'counts': {'http': httpCount, 'sockets': socketCount, 'logs': logCount},
    'warnings': const [
      'Disk space is NOT reclaimed yet — run db_vacuum to compact the file.',
    ],
    'nextSteps': const [
      'db_vacuum — reclaim disk space after the delete',
      'session_list — confirm the session no longer appears',
    ],
  });
}
