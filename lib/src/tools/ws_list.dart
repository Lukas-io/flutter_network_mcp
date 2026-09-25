import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../storage/captures_db.dart';
import '../util/filters.dart';
import '../util/scope.dart';
import 'error_kind.dart';
import 'result.dart';

final wsListTool = Tool(
  name: 'ws_list',
  description:
      'Lists the app\'s WebSocket connections: url, state, who closed it and '
      'why, message counts and bytes each way. Read from dart:io\'s own '
      'timeline events, so nothing is added to the app. Metadata only: message '
      'contents are not captured. Needs an app built with Dart 3.13+ (Flutter '
      '3.47+). Use ws_get for one connection\'s message timeline.',
  inputSchema: Schema.object(
    properties: {
      'sessionId': Schema.int(
        description:
            'Session to read from. Omit to auto-resolve (the sole attached '
            'session, or the one you opened).',
      ),
      'appNameContains': Schema.string(
        description:
            'Pick the session by app-name substring instead of sessionId.',
      ),
      'urlContains': Schema.string(
        description:
            'Only connections whose url contains this (case-insensitive).',
      ),
      'state': Schema.string(
        description:
            'Only connections in this state: connecting, open, closed, failed '
            '(the connect itself failed) or error.',
      ),
      'limit': Schema.int(
        description: 'Max connections, newest first (default 50, cap 200).',
      ),
    },
  ),
);

/// Every state a captured connection can be in.
const wsStates = ['connecting', 'open', 'closed', 'failed', 'error'];

FutureOr<CallToolResult> wsList(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final state = args['state'] as String?;
  if (state != null && !wsStates.contains(state)) {
    return errorResult('`state` must be one of ${wsStates.join(', ')}.',
        kind: ErrorKind.badArgument,
        extra: const {
          'nextSteps': ['Retry with a valid state, or omit it'],
        });
  }
  final (scope, scopeErr) = resolveScope(args);
  if (scopeErr != null) return scopeErr;
  scope!;

  final attached = scope.isLive
      ? SessionRegistry.instance.attachedById(scope.sessionId)
      : null;
  await attached?.captureWriter.refreshWebSockets();

  final urlContains = args['urlContains'] as String?;
  final limit = clampLimit(args['limit'] as int?, fallback: 50, hardMax: 200);
  final List<Map<String, Object?>> rows;
  try {
    rows = CapturesDao().queryWsConnections(
      sessionId: scope.sessionId,
      uriContains: urlContains,
      state: state,
      limit: limit,
    );
  } catch (e) {
    return errorResult('ws_list query failed: $e',
        kind: ErrorKind.internal,
        extra: {
          'sessionId': scope.sessionId,
          'nextSteps': const [
            'session_list - confirm the session id',
            'network_status - check attach state',
          ],
        });
  }

  final connections = [for (final r in rows) wsConnectionJson(r)];
  final warnings = <String>[
    if (connections.isEmpty)
      ...emptyCaptureWarnings(
        attached?.vm.webSocketTimelineSupported,
        isLive: scope.isLive,
        filtered: state != null || urlContains != null,
      ),
    if (connections.any((c) => c['uriInferred'] == true))
      'Some urls are marked uriInferred: several connects finished before '
          'their first message, so each was matched to the earliest waiting '
          'connect. Check the url against the traffic if it matters.',
  ];

  return jsonResult({
    'scope': scope.toBlock(),
    'sessionId': scope.sessionId,
    'summary': _summary(scope.sessionId, connections),
    'count': connections.length,
    if (warnings.isNotEmpty) 'warnings': warnings,
    'nextSteps': [
      if (connections.isNotEmpty)
        'ws_get id:${connections.first['id']} - message timeline of the newest connection'
      else
        'Drive the WebSocket flow in the app, then call ws_list again',
      'network_list - the HTTP upgrade request (status 101) with its headers',
    ],
    'connections': connections,
  }, scopeSessionId: scope.sessionId, scopeNote: scope.note);
}

String _summary(int sessionId, List<Map<String, Object?>> connections) {
  if (connections.isEmpty) {
    return 'No WebSocket connections captured in session $sessionId.';
  }
  final byState = <String, int>{};
  for (final c in connections) {
    final s = c['state'] as String;
    byState[s] = (byState[s] ?? 0) + 1;
  }
  final states = [for (final e in byState.entries) '${e.value} ${e.key}'];
  return '${connections.length} WebSocket connection(s) in session $sessionId '
      '(${states.join(', ')}), newest first.';
}

/// Why a capture is empty, most specific reason first.
List<String> emptyCaptureWarnings(
  bool? sdkSupported, {
  required bool isLive,
  required bool filtered,
}) {
  if (filtered) {
    return const ['No connection matches the filter; omit it to see all.'];
  }
  if (sdkSupported == false) {
    return const [
      'This app\'s Dart SDK predates WebSocket timeline events (added in Dart '
          '3.13 / Flutter 3.47), so its WebSockets cannot be seen. Rebuild the '
          'app with a newer Flutter to capture them. The HTTP upgrade request '
          'still shows in network_list, and the socket byte counters in '
          'socket_list.',
    ];
  }
  return [
    'Only dart:io WebSockets are seen (WebSocket.connect, '
        'web_socket_channel\'s IOWebSocketChannel). Native clients (OkHttp, '
        'URLSessionWebSocketTask, cupertino_http) are invisible here.',
    if (isLive)
      'Connections opened before attach appear once they send or receive, '
          'without their url.',
  ];
}

/// The agent-facing shape of one `websocket_connections` row with its totals.
Map<String, Object?> wsConnectionJson(Map<String, Object?> r) {
  final connectUs = r['connect_started_us'] as int?;
  final openedUs = r['opened_us'] as int?;
  final startedUs = connectUs ?? openedUs ?? r['first_us'] as int?;
  final endUs = r['closed_us'] as int? ?? r['last_us'] as int?;
  final closeCode = r['close_code'] as int?;
  final closeReason = r['close_reason'] as String?;
  final closedBy = r['closed_by'] as String?;
  return {
    'id': r['id'],
    'url': r['uri'],
    if ((r['uri_inferred'] as int? ?? 0) == 1) 'uriInferred': true,
    'state': r['state'],
    if (startedUs != null) 'startedMs': startedUs ~/ 1000,
    if (connectUs != null && openedUs != null)
      'connectMs': (openedUs - connectUs) ~/ 1000,
    if (startedUs != null && endUs != null && endUs >= startedUs)
      'durationMs': (endUs - startedUs) ~/ 1000,
    'sent': r['sent'] ?? 0,
    'received': r['received'] ?? 0,
    'bytesSent': r['bytes_sent'] ?? 0,
    'bytesReceived': r['bytes_received'] ?? 0,
    if (closeCode != null || closedBy != null)
      'close': [
        if (closeCode != null) '$closeCode',
        if (closeReason != null && closeReason.isNotEmpty) '"$closeReason"',
        if (closedBy != null) 'by $closedBy',
      ].join(' '),
    if (r['error'] != null) 'error': r['error'],
    if (r['http_status'] != null) 'httpStatus': r['http_status'],
    if (r['isolate_id'] != null) 'isolateId': r['isolate_id'],
  };
}
