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
      'isolateId': Schema.string(
        description:
            'Optional: clear only this isolate\'s HTTP profile. Get the id '
            'from network_status.attached[].isolates[]. Omit to clear every '
            'isolate in the session (the default).',
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
  final isolateFilter = args['isolateId'] as String?;
  // Multi-isolate: clear every isolate's profile by default; with the
  // filter, clear just the one. Per-isolate try/catch so one VM hiccup
  // doesn't stop the rest.
  final isolates = isolateFilter == null
      ? [for (final iso in attached.vm.httpProfilingIsolates) iso.id]
      : [isolateFilter];
  if (isolates.isEmpty) {
    return errorResult(
      'No HTTP-profiling isolates known for this session.',
      extra: const {
        'nextSteps': [
          'network_status — verify the session\'s isolates list',
          'network_detach then network_attach — full reset',
        ],
      },
    );
  }
  final cleared = <String>[];
  final failed = <Map<String, Object?>>[];
  for (final isoId in isolates) {
    try {
      await attached.vm.clearHttpProfileForIsolate(isoId);
      cleared.add(isoId);
    } catch (e) {
      failed.add({'isolateId': isoId, 'error': e.toString()});
    }
  }
  attached.lastHttpCursor = null;
  final liveSid = scope.sessionId;
  return jsonResult({
    'cleared': true,
    'scope': scope.toBlock(),
    'summary':
        'Live VM HTTP profile cleared for session $liveSid${scope.appName != null ? " (${scope.appName})" : ""}: ${cleared.length} isolate(s). Persistent DB is untouched (captured rows remain queryable).',
    'liveSessionId': liveSid,
    'clearedIsolates': cleared,
    if (failed.isNotEmpty) 'failed': failed,
    'warnings': [
      'The persistent DB is NOT cleared. Use session_delete or bodies_purge to remove historical rows.',
      if (failed.isNotEmpty)
        '${failed.length} isolate(s) failed to clear — see `failed` field.',
    ],
    'nextSteps': const [
      'network_list — confirm the live profile is empty',
      'Drive the app, then network_list — fresh isolated capture',
    ],
  }, scopeSessionId: scope.sessionId);
}
