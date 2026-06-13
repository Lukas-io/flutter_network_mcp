import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../storage/captures_db.dart';
import '../util/filters.dart';
import '../util/scope.dart';
import 'result.dart';

final wsListTool = Tool(
  name: 'ws_list',
  description:
      'Lists captured WebSocket connections (one row per upgraded socket with '
      'frame counts, byte totals, in/out split). Needs the '
      'flutter_network_mcp_hooks companion installed in the app; without it '
      'these are always empty (the VM profiler is blind past the HTTP '
      'upgrade). Use ws_get to read a connection\'s frames.',
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
      'limit': Schema.int(
        description:
            'Max connections returned (default 50, hard cap 200). Newest-first '
            'by start time.',
      ),
    },
  ),
);

FutureOr<CallToolResult> wsList(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final (scope, scopeErr) = resolveScope(args);
  if (scopeErr != null) return scopeErr;
  scope!;

  final limit = clampLimit(args['limit'] as int?, fallback: 50, hardMax: 200);
  final List<Map<String, Object?>> rows;
  try {
    rows = CapturesDao().queryWsConnections(
      sessionId: scope.sessionId,
      limit: limit,
    );
  } catch (e) {
    return errorResult('ws_list query failed: $e', extra: {
      'sessionId': scope.sessionId,
      'nextSteps': const [
        'session_list - confirm the session id',
        'network_status - check attach state',
      ],
    });
  }

  final connections = [for (final r in rows) _connection(r)];
  final summary = connections.isEmpty
      ? 'No WebSocket connections captured in session ${scope.sessionId}.'
      : '${connections.length} WebSocket connection(s) in session '
          '${scope.sessionId} (newest-first).';

  final warnings = <String>[];
  if (connections.isEmpty) {
    warnings.add(
      'WebSocket capture requires the flutter_network_mcp_hooks companion '
      'package. Add it as a dev_dependency and call '
      'FlutterNetworkMcpHooks.install() at the top of main() (debug mode). '
      'Apps without it expose no WebSocket frames.',
    );
    final companion = _companionDetected(scope);
    if (companion == true) {
      warnings.add(
        'Companion hooks ARE installed (extension detected) - the app just '
        'has not opened a WebSocket yet, or none since attach. Drive a '
        'WebSocket flow, then re-run.',
      );
    } else if (companion == false) {
      warnings.add(
        'Companion hooks NOT detected on the live app: the extension is '
        'absent. Confirm install() runs before runApp() and you are in a '
        'debug build.',
      );
    }
  }

  return jsonResult({
    'scope': scope.toBlock(),
    'sessionId': scope.sessionId,
    'summary': summary,
    'count': connections.length,
    if (warnings.isNotEmpty) 'warnings': warnings,
    'nextSteps': _nextSteps(connections),
    'connections': connections,
  }, scopeSessionId: scope.sessionId);
}

/// Returns true/false when the session is live (companion extension present or
/// not on the attached VM); null when the session is historical (unknowable).
bool? _companionDetected(Scope scope) {
  if (!scope.isLive) return null;
  final attached = SessionRegistry.instance.attachedById(scope.sessionId);
  if (attached == null) return null;
  return attached.vm.hasRealtimeExtension;
}

Map<String, Object?> _connection(Map<String, Object?> r) {
  final host = r['host'] as String?;
  final port = r['port'] as int?;
  final path = r['path'] as String?;
  return {
    'connId': r['conn_id'],
    if (host != null) 'host': host,
    if (port != null) 'port': port,
    if (path != null) 'path': path,
    'url': _url(host, port, path),
    if (r['started_ms'] != null) 'startedMs': r['started_ms'],
    if (r['isolate_id'] != null) 'isolateId': r['isolate_id'],
    'frameCount': r['frame_count'] ?? 0,
    'outCount': r['out_count'] ?? 0,
    'inCount': r['in_count'] ?? 0,
    'totalBytes': r['total_bytes'] ?? 0,
    if (r['last_ms'] != null) 'lastActivityMs': r['last_ms'],
  };
}

String _url(String? host, int? port, String? path) {
  final h = host ?? 'unknown';
  final p = path ?? '/';
  return port == null ? '$h$p' : '$h:$port$p';
}

List<String> _nextSteps(List<Map<String, Object?>> connections) {
  if (connections.isEmpty) {
    return const [
      'Drive a WebSocket flow in the app, then re-run ws_list',
      'socket_list - see the underlying TCP socket byte counters',
    ];
  }
  final first = connections.first;
  return [
    'ws_get connId:${first['connId']} - read this connection\'s frames',
    'socket_list - byte-level view of the same connections',
  ];
}
