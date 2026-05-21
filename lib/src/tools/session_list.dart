import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../storage/captures_db.dart';
import '../util/filters.dart';
import 'result.dart';

final sessionListTool = Tool(
  name: 'session_list',
  description:
      'Lists past capture sessions in the database (newest-first). Each '
      'session is a contiguous run between a network_attach and a '
      'network_detach (or process exit). Includes per-session counts of HTTP '
      'requests, sockets, and log records.',
  inputSchema: Schema.object(
    properties: {
      'projectPath': Schema.string(description: 'Filter by project working directory.'),
      'sinceMs': Schema.int(description: 'Only sessions started at or after this ms epoch.'),
      'limit': Schema.int(description: 'Max sessions (default 20, hard cap 100).'),
    },
  ),
);

FutureOr<CallToolResult> sessionList(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final projectPath = args['projectPath'] as String?;
  final sinceMs = args['sinceMs'] as int?;
  final limit = clampLimit(args['limit'] as int?, fallback: 20, hardMax: 100);

  try {
    final rows = CapturesDao().listSessions(
      projectPath: projectPath,
      sinceMs: sinceMs,
      limit: limit,
    );
    final live = Session.instance.liveSessionId;
    final viewed = Session.instance.viewedSessionId;
    return jsonResult({
      'count': rows.length,
      'liveSessionId': live,
      'viewedSessionId': viewed,
      'sessions': [
        for (final r in rows)
          {
            'id': r['id'],
            'startedMs': r['started_at'],
            'endedMs': r['ended_at'],
            'isLive': r['id'] == live && r['ended_at'] == null,
            'appName': r['app_name'],
            'vmServiceUri': r['vm_service_uri'],
            'isolateId': r['isolate_id'],
            'projectPath': r['project_path'],
            'note': r['note'],
            'counts': {
              'http': r['http_count'],
              'sockets': r['socket_count'],
              'logs': r['log_count'],
            },
          },
      ],
    });
  } catch (e) {
    return errorResult('session_list failed: $e');
  }
}
