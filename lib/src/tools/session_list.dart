import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../config/capabilities.dart';
import '../state/session.dart';
import '../storage/captures_db.dart';
import '../util/filters.dart';
import 'result.dart';

final sessionListTool = Tool(
  name: 'session_list',
  description:
      'Lists past capture sessions (newest-first). Each session is a '
      'contiguous run between network_attach and network_detach (or process '
      'exit). Includes per-session counts of HTTP requests, sockets, and '
      'log records. Default scope is "all"; filter by `projectPath` or '
      '`sinceMs`.',
  inputSchema: Schema.object(
    properties: {
      'projectPath': Schema.string(
        description: 'Exact-match filter on the project working directory at attach time.',
      ),
      'sinceMs': Schema.int(
        description: 'Only sessions started at or after this millis-since-epoch.',
      ),
      'limit': Schema.int(
        description: 'Max sessions returned (default 20, hard cap 100). Newest-first.',
      ),
    },
  ),
);

FutureOr<CallToolResult> sessionList(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final caps = CapabilityConfig.instance;
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
    final sessions = [
      for (final r in rows)
        {
          'id': r['id'],
          'startedMs': r['started_at'],
          if (r['ended_at'] != null) 'endedMs': r['ended_at'],
          'isLive': r['id'] == live && r['ended_at'] == null,
          if (r['app_name'] != null) 'appName': r['app_name'],
          if (r['project_path'] != null) 'projectPath': r['project_path'],
          if (r['note'] != null) 'note': r['note'],
          'counts': {
            'http': r['http_count'],
            'sockets': r['socket_count'],
            'logs': r['log_count'],
          },
        },
    ];

    final filterDesc = _filterDesc(projectPath, sinceMs);
    final summary = sessions.isEmpty
        ? 'No capture sessions in DB${filterDesc.isEmpty ? "" : " matching $filterDesc"}.'
        : '${sessions.length} session(s)${filterDesc.isEmpty ? "" : " (filtered: $filterDesc)"} — live: ${live ?? "none"}, viewing: ${viewed ?? "live"}.';

    final warnings = <String>[];
    if (sessions.isEmpty) {
      warnings.add('No sessions match — drop filters or call network_attach to create one.');
    } else if (sessions.length >= 50) {
      warnings.add('Large session count — consider db_stats / bodies_purge / session_delete to manage DB growth.');
    }

    final nextSteps = <String>[];
    if (sessions.isEmpty) {
      nextSteps.add('network_status — see if an app is running');
      nextSteps.add('network_attach — start a new session');
    } else {
      final pickable = sessions.firstWhere(
        (s) => s['isLive'] == false,
        orElse: () => sessions.first,
      );
      nextSteps.add('session_open id:${pickable['id']} — read its captures');
      if (caps.isEnabled(Category.sessions)) {
        nextSteps.add('session_export id:<n> format:"har" outPath:"..." — share a session as HAR');
      }
      if (sessions.length >= 50) {
        nextSteps.add('session_delete id:<old session> confirm:true — prune oldest after backup');
      }
    }

    return jsonResult({
      'summary': summary,
      'count': sessions.length,
      'liveSessionId': live,
      'viewedSessionId': viewed,
      if (warnings.isNotEmpty) 'warnings': warnings,
      'nextSteps': nextSteps,
      'sessions': sessions,
    });
  } catch (e) {
    return errorResult('session_list failed: $e', extra: const {
      'nextSteps': [
        'network_status — confirm DB is open',
        'db_stats — check DB health',
      ],
    });
  }
}

String _filterDesc(String? projectPath, int? sinceMs) {
  final parts = <String>[];
  if (projectPath != null) parts.add('projectPath="$projectPath"');
  if (sinceMs != null) parts.add('sinceMs=$sinceMs');
  return parts.join(', ');
}
