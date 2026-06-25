import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../config/capabilities.dart';
import '../state/session.dart';
import '../storage/captures_db.dart';
import '../util/filters.dart';
import 'error_kind.dart';
import 'result.dart';

final sessionListTool = Tool(
  name: 'session_list',
  description:
      'Lists past capture sessions (newest-first) with per-session '
      'HTTP/socket/log counts. Scope to one app with appNameContains (the DTD '
      'identity); projectPath is just the cwd at attach and several apps can '
      'share it.',
  inputSchema: Schema.object(
    properties: {
      'appNameContains': Schema.string(
        description:
            'Case-insensitive substring on the app name (DTD identity). The '
            'reliable way to scope to one app.',
      ),
      'projectPath': Schema.string(
        description:
            'Exact cwd at attach. NOT app identity (apps from one dir share '
            'it); prefer appNameContains.',
      ),
      'sinceMs': Schema.int(
        description: 'Only sessions started at or after this ms-since-epoch.',
      ),
      'limit': Schema.int(
        description: 'Max sessions (default 20, cap 100).',
      ),
    },
  ),
);

FutureOr<CallToolResult> sessionList(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final caps = CapabilityConfig.instance;
  final appNameContains = args['appNameContains'] as String?;
  final projectPath = args['projectPath'] as String?;
  final sinceMs = args['sinceMs'] as int?;
  final limit = clampLimit(args['limit'] as int?, fallback: 20, hardMax: 100);

  try {
    final rows = CapturesDao().listSessions(
      projectPath: projectPath,
      appNameContains: appNameContains,
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

    final filterDesc = _filterDesc(appNameContains, projectPath, sinceMs);
    final summary = sessions.isEmpty
        ? 'No capture sessions in DB${filterDesc.isEmpty ? "" : " matching $filterDesc"}.'
        : '${sessions.length} session(s)${filterDesc.isEmpty ? "" : " (filtered: $filterDesc)"} — live: ${live ?? "none"}, viewing: ${viewed ?? "live"}.';

    final warnings = <String>[];
    if (sessions.isEmpty) {
      warnings.add('No sessions match — drop filters or call network_attach to create one.');
    } else if (sessions.length >= 50) {
      warnings.add('Large session count — consider db_stats / bodies_purge / session_delete to manage DB growth.');
    }

    final distinctApps = {
      for (final s in sessions)
        if (s['appName'] != null) s['appName'] as String,
    };
    final distinctPaths = {
      for (final s in sessions)
        if (s['projectPath'] != null) s['projectPath'] as String,
    };
    if (distinctApps.length > 1 && distinctPaths.length < distinctApps.length) {
      warnings.add(
        'projectPath is the working directory at attach time, not app '
        'identity: ${distinctApps.length} distinct apps here share a '
        'directory (${distinctApps.join(", ")}). Filter with '
        'appNameContains:"<app>" to scope to one app.',
      );
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
      if (distinctApps.length > 1) {
        nextSteps.add(
          'session_list appNameContains:"${distinctApps.first}" to scope to one app',
        );
      }
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
    return errorResult('session_list failed: $e', kind: ErrorKind.internal, extra: const {
      'nextSteps': [
        'network_status — confirm DB is open',
        'db_stats — check DB health',
      ],
    });
  }
}

String _filterDesc(String? appNameContains, String? projectPath, int? sinceMs) {
  final parts = <String>[];
  if (appNameContains != null && appNameContains.isNotEmpty) {
    parts.add('appNameContains="$appNameContains"');
  }
  if (projectPath != null) parts.add('projectPath="$projectPath"');
  if (sinceMs != null) parts.add('sinceMs=$sinceMs');
  return parts.join(', ');
}
