import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../storage/captures_db.dart';
import '../util/filters.dart';
import '../util/scope.dart';
import 'error_kind.dart';
import 'result.dart';
import 'ws_list.dart';

final wsGetTool = Tool(
  name: 'ws_get',
  description:
      'One WebSocket connection (id from ws_list) and its event timeline in '
      'order: each message\'s time since the connection started, direction '
      '(out = app to server, in = server to app), type (text, binary, ping, '
      'pong, close, error) and size. Contents are not captured.',
  inputSchema: Schema.object(
    properties: {
      'id': Schema.int(description: 'Connection id from ws_list.'),
      'sessionId': Schema.int(
        description:
            'Session to read from. Omit to auto-resolve (the sole attached '
            'session, or the one you opened).',
      ),
      'appNameContains': Schema.string(
        description:
            'Pick the session by app-name substring instead of sessionId.',
      ),
      'direction': Schema.string(description: '"out" or "in". Omit for both.'),
      'kind': Schema.string(
        description:
            'Only this event type: text, binary, ping, pong, close or error.',
      ),
      'afterId': Schema.int(
        description: 'Page on: pass the previous reply\'s nextAfterId.',
      ),
      'limit': Schema.int(
        description: 'Max events, oldest first (default 100, cap 500).',
      ),
    },
    required: ['id'],
  ),
);

const _kinds = ['text', 'binary', 'ping', 'pong', 'close', 'error'];

FutureOr<CallToolResult> wsGet(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final id = args['id'] as int?;
  if (id == null) {
    return errorResult('Missing required arg `id` (int).',
        kind: ErrorKind.badArgument,
        extra: const {
          'nextSteps': ['ws_list - list connections and pick an id'],
        });
  }
  final direction = args['direction'] as String?;
  if (direction != null && direction != 'out' && direction != 'in') {
    return errorResult('`direction` must be "out" or "in".',
        kind: ErrorKind.badArgument,
        extra: const {
          'nextSteps': [
            'Retry with direction:"out", direction:"in", or omit it'
          ],
        });
  }
  final kind = args['kind'] as String?;
  if (kind != null && !_kinds.contains(kind)) {
    return errorResult('`kind` must be one of ${_kinds.join(', ')}.',
        kind: ErrorKind.badArgument,
        extra: const {
          'nextSteps': ['Retry with a valid kind, or omit it'],
        });
  }
  final (scope, scopeErr) = resolveScope(args);
  if (scopeErr != null) return scopeErr;
  scope!;

  if (scope.isLive) {
    await SessionRegistry.instance
        .attachedById(scope.sessionId)
        ?.captureWriter
        .refreshWebSockets();
  }

  final dao = CapturesDao();
  final conn = dao.getWsConnection(scope.sessionId, id);
  if (conn == null) {
    return errorResult(
      'WebSocket connection $id not found in session ${scope.sessionId}.',
      kind: ErrorKind.notFound,
      extra: {
        'sessionId': scope.sessionId,
        'nextSteps': const [
          'ws_list - list valid ids in this session',
          'session_list - confirm the session id',
        ],
      },
    );
  }

  final limit = clampLimit(args['limit'] as int?, fallback: 100, hardMax: 500);
  final rows = dao.queryWsMessages(
    sessionId: scope.sessionId,
    connKey: conn['conn_key'] as String,
    kind: kind,
    direction: direction,
    afterId: args['afterId'] as int?,
    limit: limit + 1,
  );
  final more = rows.length > limit;
  final page = more ? rows.sublist(0, limit) : rows;
  final originUs = conn['connect_started_us'] as int? ??
      conn['opened_us'] as int? ??
      conn['first_us'] as int?;
  final connection = wsConnectionJson(conn);
  final filter = [
    if (direction != null) 'direction $direction',
    if (kind != null) 'kind $kind',
  ].join(', ');

  return jsonResult({
    'scope': scope.toBlock(),
    'sessionId': scope.sessionId,
    'summary': page.isEmpty
        ? 'Connection $id (${connection['url'] ?? 'url unknown'}) has no events'
            '${filter.isEmpty ? '' : ' matching $filter'}.'
        : '${page.length} event(s) of connection $id '
            '(${connection['url'] ?? 'url unknown'}, ${connection['state']})'
            '${filter.isEmpty ? '' : ', $filter'}, oldest first.',
    'connection': connection,
    'eventFormat':
        '+seconds since start, direction, type, size or close detail',
    'events': [for (final r in page) _event(r, originUs)],
    if (more) 'nextAfterId': page.last['id'],
    'nextSteps': [
      if (more) 'ws_get id:$id afterId:${page.last['id']} - next page',
      'ws_list - the other connections',
      if (connection['url'] == null)
        'network_list - the upgrade request (status 101) names the url',
    ],
  }, scopeSessionId: scope.sessionId, scopeNote: scope.note);
}

/// One event as `+1.204s out text 239B`.
String _event(Map<String, Object?> r, int? originUs) {
  final ts = r['ts_us'] as int;
  final offset = originUs == null
      ? ''
      : '+${((ts - originUs) ~/ 1000 / 1000).toStringAsFixed(3)}s ';
  final bytes = r['bytes'] as int?;
  final detail = r['detail'] as String?;
  return [
    '$offset${r['direction'] ?? '-'} ${r['kind']}',
    if (bytes != null) '${bytes}B',
    if (detail != null && detail.isNotEmpty) detail,
  ].join(' ');
}
