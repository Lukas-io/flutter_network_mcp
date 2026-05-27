import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../util/scope.dart';
import 'result.dart';

final networkClearTool = Tool(
  name: 'network_clear',
  description:
      'Wipes the LIVE in-VM HTTP profile on the attached isolate and resets '
      'the session cursor. **Does NOT touch the persistent DB** — past '
      'captures stay queryable via session_open. Use bodies_purge / '
      'session_delete for DB-side cleanup.',
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

FutureOr<CallToolResult> networkClear(CallToolRequest request) async {
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
          'bodies_purge sessionId:<N> — drop body BLOBs from the DB instead',
          'session_delete id:<N> — drop the entire session from the DB',
        ],
      },
    );
  }
  final attached = SessionRegistry.instance.attachedById(scope.sessionId)!;
  try {
    await attached.vm.clearHttpProfile();
    attached.lastHttpCursor = null;
    final liveSid = scope.sessionId;
    return jsonResult({
      'cleared': true,
      'scope': scope.toBlock(),
      'summary':
          'Live VM HTTP profile cleared for session $liveSid${scope.appName != null ? " (${scope.appName})" : ""}. Persistent DB is untouched (captured rows remain queryable).',
      'liveSessionId': liveSid,
      'warnings': const [
        'The persistent DB is NOT cleared. Use session_delete or bodies_purge to remove historical rows.',
      ],
      'nextSteps': const [
        'network_list — confirm the live profile is empty',
        'Drive the app, then network_list — fresh isolated capture',
      ],
    });
  } catch (e) {
    return errorResult('clearHttpProfile failed: $e', extra: const {
      'nextSteps': [
        'network_status — check zombie-DTD state',
        'network_detach then network_attach — full reset',
      ],
    });
  }
}
