import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../storage/captures_db.dart';
import 'result.dart';

final sessionDeleteTool = Tool(
  name: 'session_delete',
  description:
      'Deletes a session and ALL its captured data: requests, bodies, '
      'sockets, logs, alerts, and search index rows. Cannot be undone. The '
      'live session cannot be deleted — detach first.',
  inputSchema: Schema.object(
    properties: {
      'id': Schema.int(description: 'Session id to delete.'),
      'confirm': Schema.bool(
        description: 'Must be true to actually delete. Default false (dry-run).',
      ),
    },
    required: ['id'],
  ),
);

FutureOr<CallToolResult> sessionDelete(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final id = args['id'] as int?;
  final confirm = (args['confirm'] as bool?) ?? false;
  if (id == null) return errorResult('Missing required arg `id`.');

  final session = Session.instance;
  if (session.liveSessionId == id) {
    return errorResult('Cannot delete the live session — call network_detach first.');
  }

  final dao = CapturesDao();
  final row = dao.getSession(id);
  if (row == null) return errorResult('Session $id not found.');

  if (!confirm) {
    return jsonResult({
      'dryRun': true,
      'sessionId': id,
      'appName': row['app_name'],
      'startedMs': row['started_at'],
      'note': row['note'],
      'message': 'Pass confirm:true to actually delete.',
    });
  }

  if (session.viewedSessionId == id) {
    session.viewedSessionId = null;
  }
  final deleted = dao.deleteSession(id);
  return jsonResult({'deleted': deleted, 'sessionId': id});
}
