import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import 'result.dart';

final networkClearTool = Tool(
  name: 'network_clear',
  description:
      'Wipes the LIVE in-VM HTTP profile on the attached isolate and resets '
      'the session cursor. **Does NOT touch the persistent DB** — past '
      'captures stay queryable via session_open. Use bodies_purge / '
      'session_delete for DB-side cleanup.',
  inputSchema: Schema.object(properties: {}),
);

FutureOr<CallToolResult> networkClear(CallToolRequest request) async {
  final session = Session.instance;
  if (!session.isAttached) {
    return errorResult(
      'Not attached — nothing to clear in the live VM profile.',
      extra: const {
        'nextSteps': [
          'network_attach — connect to a live app first',
          'bodies_purge / session_delete — for DB-side cleanup instead',
        ],
      },
    );
  }
  try {
    await session.vm.clearHttpProfile();
    session.lastHttpCursor = null;
    final liveSid = session.liveSessionId;
    return jsonResult({
      'cleared': true,
      'summary':
          'Live VM HTTP profile cleared. Persistent DB session $liveSid is untouched (captured rows remain queryable).',
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
