import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../storage/captures_db.dart';
import '../util/filters.dart';
import '../util/scope.dart';
import 'result.dart';

final wsGetTool = Tool(
  name: 'ws_get',
  description:
      'Returns the captured frames (messages) of one WebSocket connection by '
      'connId (from ws_list), oldest-first so a conversation reads top to '
      'bottom. Each frame carries direction, opcode, length, and a decoded '
      'preview (text inline, binary as hex). Text frames are reassembled + '
      'decompressed; ping/pong keepalives are dropped.',
  inputSchema: Schema.object(
    properties: {
      'connId': Schema.int(description: 'Connection id from ws_list.'),
      'sessionId': Schema.int(
        description:
            'Session to read from. Omit to auto-resolve (the sole attached '
            'session, or the one you opened).',
      ),
      'appNameContains': Schema.string(
        description:
            'Pick the session by app-name substring instead of sessionId.',
      ),
      'dir': Schema.string(
        description:
            'Filter to one direction: "out" (app to server) or "in" (server '
            'to app). Omit for both.',
      ),
      'limit': Schema.int(
        description:
            'Max frames returned (default 100, hard cap 500). Caps to the most '
            'recent N, then presented oldest-first.',
      ),
    },
    required: ['connId'],
  ),
);

FutureOr<CallToolResult> wsGet(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final connId = args['connId'] as int?;
  if (connId == null) {
    return errorResult('Missing required arg `connId` (int).', extra: const {
      'nextSteps': ['ws_list - list connections and pick a connId'],
    });
  }
  final dir = args['dir'] as String?;
  if (dir != null && dir != 'out' && dir != 'in') {
    return errorResult('`dir` must be "out" or "in".', extra: const {
      'nextSteps': ['Retry with dir:"out", dir:"in", or omit it'],
    });
  }
  final (scope, scopeErr) = resolveScope(args);
  if (scopeErr != null) return scopeErr;
  scope!;

  final dao = CapturesDao();
  final conn = dao.getWsConnection(scope.sessionId, connId);
  if (conn == null) {
    return errorResult(
      'WebSocket connection $connId not found in session ${scope.sessionId}.',
      extra: {
        'sessionId': scope.sessionId,
        'nextSteps': const [
          'ws_list - list valid connIds in this session',
          'session_list - confirm the session id',
        ],
      },
    );
  }

  final limit = clampLimit(args['limit'] as int?, fallback: 100, hardMax: 500);
  final rows = dao.queryWsFrames(
    sessionId: scope.sessionId,
    connId: connId,
    direction: dir,
    limit: limit,
  );
  // queryWsFrames returns newest-first (so the limit keeps the most recent
  // window); reverse to chronological for reading.
  final frames = [for (final r in rows.reversed) _frame(r)];

  final host = conn['host'] as String?;
  final port = conn['port'] as int?;
  final path = conn['path'] as String?;
  final endpoint = port == null
      ? '${host ?? "unknown"}${path ?? "/"}'
      : '${host ?? "unknown"}:$port${path ?? "/"}';

  return jsonResult({
    'scope': scope.toBlock(),
    'sessionId': scope.sessionId,
    'connId': connId,
    'url': endpoint,
    if (conn['started_ms'] != null) 'startedMs': conn['started_ms'],
    'summary': frames.isEmpty
        ? 'Connection $connId ($endpoint) has no captured frames'
            '${dir != null ? ' in direction "$dir"' : ''}.'
        : '${frames.length} frame(s) for connection $connId ($endpoint)'
            '${dir != null ? ', dir "$dir"' : ''}, oldest-first.',
    'count': frames.length,
    'nextSteps': [
      'ws_list - see sibling connections',
      if (frames.isNotEmpty)
        'ws_get connId:$connId dir:"out" - filter to outbound frames',
    ],
    'frames': frames,
  }, scopeSessionId: scope.sessionId);
}

Map<String, Object?> _frame(Map<String, Object?> r) {
  return {
    if (r['ts_ms'] != null) 'tsMs': r['ts_ms'],
    'dir': r['direction'],
    'opcode': r['opcode'],
    'len': r['length'] ?? 0,
    'isText': (r['is_text'] as int? ?? 0) == 1,
    if ((r['compressed'] as int? ?? 0) == 1) 'compressed': true,
    'preview': r['preview'],
  };
}
