import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import 'result.dart';

final logsClearTool = Tool(
  name: 'logs_clear',
  description:
      'Empties the in-memory log ring buffer. **Does NOT affect the app or '
      'the persistent DB** — new log/stdout/stderr events will continue to '
      'fill the buffer, and DB `log_records` rows remain queryable via '
      'session_open + logs_tail.',
  inputSchema: Schema.object(properties: {}),
);

FutureOr<CallToolResult> logsClear(CallToolRequest request) async {
  final session = Session.instance;
  final before = session.logBuffer.length;
  session.logBuffer.clear();
  return jsonResult({
    'cleared': true,
    'summary': before == 0
        ? 'Ring buffer was already empty (nothing to clear).'
        : 'Cleared $before log record(s) from live ring buffer. Persistent DB log_records untouched.',
    'clearedCount': before,
    'streamActive': session.logStream.isActive,
    'warnings': const [
      'The persistent DB is NOT cleared. Use session_delete for DB-side removal.',
    ],
    'nextSteps': const [
      'logs_tail — confirm the live buffer is empty',
      'Drive the app, then logs_tail — fresh isolated capture',
    ],
  });
}
