import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../config/capabilities.dart';
import '../state/session.dart';
import '../storage/captures_db.dart';
import 'result.dart';

final sessionOpenTool = Tool(
  name: 'session_open',
  description:
      'Switches the read pointer used by network_list, network_get, '
      'network_body, socket_list, socket_get, logs_tail, network_search, and '
      'network_diff to the given session. The live capture continues '
      'writing into its own session regardless. Call session_close to revert.',
  inputSchema: Schema.object(
    properties: {
      'id': Schema.int(description: 'Session id from session_list.'),
    },
    required: ['id'],
  ),
);

FutureOr<CallToolResult> sessionOpen(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final caps = CapabilityConfig.instance;
  final id = args['id'] as int?;
  if (id == null) {
    return errorResult('Missing required arg `id`.', extra: const {
      'nextSteps': [
        'session_list — find a session id',
      ],
    });
  }

  try {
    final dao = CapturesDao();
    final row = dao.getSession(id);
    if (row == null) {
      return errorResult('Session $id not found.', extra: const {
        'nextSteps': [
          'session_list — see valid session ids',
        ],
      });
    }

    Session.instance.viewedSessionId = id;
    final isLive = Session.instance.liveSessionId == id;
    final appName = row['app_name'] as String?;
    final startedMs = row['started_at'];
    final endedMs = row['ended_at'];
    final isEnded = endedMs != null;

    final summary = isEnded
        ? 'Viewing session $id (${appName ?? "unnamed"}, ended) — read tools now query history.'
        : 'Viewing session $id (${appName ?? "unnamed"}, still live${isLive ? " — current attach" : ""}).';

    final warnings = <String>[];
    if (isLive) {
      warnings.add('You opened the live session — read tools work the same as without session_open.');
    }

    final nextSteps = <String>[];
    if (caps.isEnabled(Category.http)) {
      nextSteps.add('network_list — list the http requests in this session');
    }
    if (caps.isEnabled(Category.search)) {
      nextSteps.add('network_search query:"..." — full-text search this session');
    }
    nextSteps.add('session_close — revert read pointer to live');

    return jsonResult({
      'summary': summary,
      'viewedSessionId': id,
      if (appName != null) 'appName': appName,
      'startedMs': startedMs,
      if (endedMs != null) 'endedMs': endedMs,
      'isLive': isLive,
      'isEnded': isEnded,
      if (row['project_path'] != null) 'projectPath': row['project_path'],
      if (row['note'] != null) 'note': row['note'],
      if (warnings.isNotEmpty) 'warnings': warnings,
      'nextSteps': nextSteps,
    });
  } catch (e) {
    return errorResult('session_open failed: $e', extra: {
      'sessionId': id,
      'nextSteps': const [
        'session_list — confirm the session id exists',
      ],
    });
  }
}
