import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import 'result.dart';

final socketClearTool = Tool(
  name: 'socket_clear',
  description:
      'Wipes the LIVE in-VM socket profile on the attached isolate. **Does '
      'NOT touch the persistent DB** — captured rows in `socket_events` '
      'remain queryable.',
  inputSchema: Schema.object(properties: {}),
);

FutureOr<CallToolResult> socketClear(CallToolRequest request) async {
  final session = Session.instance;
  if (!session.isAttached) {
    return errorResult(
      'Not attached — nothing to clear in the live VM socket profile.',
      extra: const {
        'nextSteps': [
          'network_attach — connect to a live app first',
          'session_delete — for DB-side cleanup instead',
        ],
      },
    );
  }
  if (!session.socketProfilingEnabled) {
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
    await session.vm.clearSocketProfile();
    return jsonResult({
      'cleared': true,
      'summary':
          'Live VM socket profile cleared. Persistent DB session ${session.liveSessionId} is untouched (socket_events rows remain queryable).',
      'liveSessionId': session.liveSessionId,
      'warnings': const [
        'The persistent DB is NOT cleared. Use session_delete for DB-side removal.',
      ],
      'nextSteps': const [
        'socket_list — confirm the live profile is empty',
        'Drive the app, then socket_list — fresh isolated socket capture',
      ],
    });
  } catch (e) {
    return errorResult('clearSocketProfile failed: $e', extra: const {
      'nextSteps': [
        'network_status — check zombie-DTD state',
        'network_detach then network_attach — full reset',
      ],
    });
  }
}
