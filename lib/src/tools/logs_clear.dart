import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../util/scope.dart';
import 'result.dart';

final logsClearTool = Tool(
  name: 'logs_clear',
  description:
      'Empties the in-memory log ring buffer for the scoped session. **Does '
      'NOT affect the app or the persistent DB** — new log/stdout/stderr '
      'events will continue to fill the buffer, and DB `log_records` rows '
      'remain queryable via session_open + logs_tail.',
  inputSchema: Schema.object(
    properties: {
      'sessionId': Schema.int(
        description:
            'Which attached session\'s buffer to clear. Omit when exactly '
            'one is attached.',
      ),
      'appNameContains': Schema.string(
        description:
            'Alternative to sessionId — case-insensitive substring on a '
            'currently-attached app name.',
      ),
    },
  ),
);

FutureOr<CallToolResult> logsClear(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final (scope, scopeErr) = resolveScope(args);
  if (scopeErr != null) return scopeErr;
  scope!;

  if (!scope.isLive) {
    return errorResult(
      'Cannot clear a historical session\'s buffer — there is no live ring buffer to clear.',
      extra: {
        'scope': scope.toBlock(),
        'nextSteps': const [
          'network_attach — connect to a live app first',
          'session_delete id:<N> — drop the entire session from the DB',
        ],
      },
    );
  }
  final attached = SessionRegistry.instance.attachedById(scope.sessionId)!;
  final before = attached.logBuffer.length;
  attached.logBuffer.clear();
  return jsonResult({
    'cleared': true,
    'scope': scope.toBlock(),
    'summary': before == 0
        ? 'Ring buffer was already empty for session ${scope.sessionId} (nothing to clear).'
        : 'Cleared $before log record(s) from live ring buffer for session ${scope.sessionId}${scope.appName != null ? " (${scope.appName})" : ""}. Persistent DB log_records untouched.',
    'clearedCount': before,
    'streamActive': attached.logStream.isActive,
    'warnings': const [
      'The persistent DB is NOT cleared. Use session_delete for DB-side removal.',
    ],
    'nextSteps': const [
      'logs_tail — confirm the live buffer is empty',
      'Drive the app, then logs_tail — fresh isolated capture',
    ],
  });
}
