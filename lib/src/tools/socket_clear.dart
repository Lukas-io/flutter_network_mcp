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
      'Socket profiling is not enabled for this isolate.',
      extra: const {
        'nextSteps': [
          'network_status — confirm socketProfilingEnabled',
          'Re-attach the app',
        ],
      },
    );
  }
  try {
    await attached.vm.clearSocketProfile();
    return jsonResult({
      'cleared': true,
      'scope': scope.toBlock(),
      'summary':
          'Live VM socket profile cleared for session ${scope.sessionId}${scope.appName != null ? " (${scope.appName})" : ""}. Persistent DB is untouched (socket_events rows remain queryable).',
      'liveSessionId': scope.sessionId,
      'warnings': const [
        'The persistent DB is NOT cleared. Use session_delete for DB-side removal.',
      ],
      'nextSteps': const [
        'socket_list — confirm the live profile is empty',
        'Drive the app, then socket_list — fresh isolated socket capture',
      ],
    }, scopeSessionId: scope.sessionId);
  } catch (e) {
    return errorResult('clearSocketProfile failed: $e', extra: const {
      'nextSteps': [
        'network_status — check zombie-DTD state',
        'network_detach then network_attach — full reset',
      ],
    });
  }
}
