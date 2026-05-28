import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../util/scope.dart';
import 'result.dart';

final socketClearTool = Tool(
  name: 'socket_clear',
  description:
      'Wipes the LIVE in-VM socket profile on the attached isolate. **Does '
      'NOT touch the persistent DB** — captured rows in `socket_events` '
      'remain queryable.',
  inputSchema: Schema.object(
    properties: {
      'sessionId': Schema.int(
        description:
            'Which attached session to clear. Omit when exactly one is '
            'attached; required when 2+ are attached (multi-attach).',
      ),
      'appNameContains': Schema.string(
        description:
            'Alternative to sessionId — case-insensitive substring on a '
            'currently-attached app name.',
      ),
      'isolateId': Schema.string(
        description:
            'Optional: clear only this isolate\'s socket profile. Get the id '
            'from network_status.attached[].isolates[]. Omit to clear every '
            'isolate in the session (the default).',
      ),
    },
  ),
);

FutureOr<CallToolResult> socketClear(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final (scope, scopeErr) = resolveScope(args);
  if (scopeErr != null) return scopeErr;
  scope!;

  if (!scope.isLive) {
    return errorResult(
      'Cannot clear a historical session — there is no live VM to clear.',
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
  if (!attached.socketProfilingEnabled) {
    return errorResult(
      'Socket profiling is not enabled for any of this session\'s isolates.',
      extra: const {
        'nextSteps': [
          'network_status — confirm socketProfilingEnabled',
          'Re-attach the app',
        ],
      },
    );
  }
  final isolateFilter = args['isolateId'] as String?;
  final isolates = isolateFilter == null
      ? [for (final iso in attached.vm.httpProfilingIsolates) iso.id]
      : [isolateFilter];
  final cleared = <String>[];
  final failed = <Map<String, Object?>>[];
  for (final isoId in isolates) {
    try {
      await attached.vm.clearSocketProfileForIsolate(isoId);
      cleared.add(isoId);
    } catch (e) {
      // Socket profiling might be enabled on only some isolates — ignore
      // misses on isolates that don't support it.
      failed.add({'isolateId': isoId, 'error': e.toString()});
    }
  }
  return jsonResult({
    'cleared': true,
    'scope': scope.toBlock(),
    'summary':
        'Live VM socket profile cleared for session ${scope.sessionId}${scope.appName != null ? " (${scope.appName})" : ""}: ${cleared.length} isolate(s). Persistent DB is untouched (socket_events rows remain queryable).',
    'liveSessionId': scope.sessionId,
    'clearedIsolates': cleared,
    if (failed.isNotEmpty) 'failed': failed,
    'warnings': [
      'The persistent DB is NOT cleared. Use session_delete for DB-side removal.',
      if (failed.isNotEmpty)
        '${failed.length} isolate(s) failed to clear — see `failed` field.',
    ],
    'nextSteps': const [
      'socket_list — confirm the live profile is empty',
      'Drive the app, then socket_list — fresh isolated socket capture',
    ],
  }, scopeSessionId: scope.sessionId);
}
