import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../storage/captures_db.dart';
import 'result.dart';

final sessionOpenTool = Tool(
  name: 'session_open',
  description:
      'Switches the read pointer used by network_list, network_get, '
      'network_body, socket_list, socket_get, and logs_tail to the given '
      'session in the database. The live capture continues to write into '
      'its own session regardless. Call session_close to revert to live.',
  inputSchema: Schema.object(
    properties: {
      'id': Schema.int(description: 'Session id from session_list.'),
    },
    required: ['id'],
  ),
);

FutureOr<CallToolResult> sessionOpen(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final id = args['id'] as int?;
  if (id == null) return errorResult('Missing required arg `id`.');

  final row = CapturesDao().getSession(id);
  if (row == null) return errorResult('Session $id not found.');

  Session.instance.viewedSessionId = id;
  return jsonResult({
    'viewedSessionId': id,
    'appName': row['app_name'],
    'startedMs': row['started_at'],
    'endedMs': row['ended_at'],
    'projectPath': row['project_path'],
  });
}
