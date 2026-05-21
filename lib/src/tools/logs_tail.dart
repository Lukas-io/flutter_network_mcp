import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../storage/captures_db.dart';
import '../util/filters.dart';
import 'result.dart';

const int _kMessageTruncateBytes = 2048;

final logsTailTool = Tool(
  name: 'logs_tail',
  description:
      'Returns recent VM service log/stdout/stderr records. In live mode '
      '(default), reads from an in-memory ring buffer (capacity 500). In '
      'history mode (session_open active), reads from the persistent DB.',
  inputSchema: Schema.object(
    properties: {
      'since': Schema.int(description: 'Cursor id from a prior nextCursor.'),
      'levelMin': Schema.int(
        description:
            'Minimum severity (package:logging scale 0–2000). Applies to '
            'Logging records only.',
      ),
      'loggerContains': Schema.string(description: 'Substring match on logger name.'),
      'source': Schema.string(description: '"logging" | "stdout" | "stderr".'),
      'limit': Schema.int(description: 'Max results (default 100, hard cap 500).'),
    },
  ),
);

FutureOr<CallToolResult> logsTail(CallToolRequest request) async {
  final session = Session.instance;
  final args = request.arguments ?? const <String, Object?>{};
  final sinceId = args['since'] as int?;
  final levelMin = args['levelMin'] as int?;
  final loggerContains = args['loggerContains'] as String?;
  final source = args['source'] as String?;
  final limit = clampLimit(args['limit'] as int?, fallback: 100, hardMax: 500);

  if (session.isViewingHistory) {
    final sid = session.viewedSessionId!;
    try {
      final rows = CapturesDao().queryLogs(
        sessionId: sid,
        sinceId: sinceId,
        levelMin: levelMin,
        loggerContains: loggerContains,
        source: source,
        limit: limit,
      );
      int? maxId;
      final out = <Map<String, Object?>>[];
      for (final r in rows) {
        final id = r['id'] as int;
        if (maxId == null || id > maxId) maxId = id;
        final msg = (r['message'] as String?) ?? '';
        final truncated = msg.length > _kMessageTruncateBytes;
        out.add({
          'id': id,
          'source': r['source'],
          'timestampMs': r['timestamp_ms'],
          'level': r['level'],
          'loggerName': r['logger'],
          'message': truncated ? msg.substring(0, _kMessageTruncateBytes) : msg,
          if (truncated) 'truncated': true,
          if (truncated) 'totalLength': msg.length,
          if (r['error'] != null) 'error': r['error'],
          if (r['stack_trace'] != null) 'stackTrace': r['stack_trace'],
        });
      }
      return jsonResult({
        'source': 'history',
        'sessionId': sid,
        'count': out.length,
        'nextCursor': maxId,
        'entries': out,
      });
    } catch (e) {
      return errorResult('history query failed: $e');
    }
  }

  // Live mode — read from ring buffer.
  final entries = session.logBuffer.tail(
    sinceId: sinceId,
    levelMin: levelMin,
    loggerContains: loggerContains,
    sourceContains: source,
    limit: limit,
  );
  final out = <Map<String, Object?>>[];
  int? maxId;
  for (final e in entries) {
    if (maxId == null || e.id > maxId) maxId = e.id;
    final msg = e.message;
    final truncated = msg.length > _kMessageTruncateBytes;
    out.add({
      'id': e.id,
      'source': e.source,
      'timestampMs': e.timestampMs,
      'level': e.level,
      'loggerName': e.loggerName,
      'message': truncated ? msg.substring(0, _kMessageTruncateBytes) : msg,
      if (truncated) 'truncated': true,
      if (truncated) 'totalLength': msg.length,
      if (e.error != null) 'error': e.error,
      if (e.stackTrace != null) 'stackTrace': e.stackTrace,
    });
  }
  return jsonResult({
    'source': 'live',
    'sessionId': session.liveSessionId,
    'count': out.length,
    'bufferSize': session.logBuffer.length,
    'streamActive': session.logStream.isActive,
    'nextCursor': maxId,
    'entries': out,
  });
}
