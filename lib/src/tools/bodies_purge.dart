import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../storage/captures_db.dart';
import 'result.dart';

final bodiesPurgeTool = Tool(
  name: 'bodies_purge',
  description:
      'Drops captured request/response BLOBs while preserving the '
      'http_requests summary metadata. Useful to shrink the DB without '
      'losing the trace of what happened. Pass `sessionId` for a single '
      'session, `olderThanMs` to purge across sessions, or both.',
  inputSchema: Schema.object(
    properties: {
      'sessionId': Schema.int(description: 'Restrict to a session id.'),
      'olderThanMs': Schema.int(
        description:
            'Millis-since-epoch. Bodies of requests whose start time is older '
            'than this are purged.',
      ),
      'confirm': Schema.bool(
        description: 'Must be true to actually purge. Default false (dry-run).',
      ),
    },
  ),
);

FutureOr<CallToolResult> bodiesPurge(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final sessionId = args['sessionId'] as int?;
  final olderThanMs = args['olderThanMs'] as int?;
  final confirm = (args['confirm'] as bool?) ?? false;

  if (sessionId == null && olderThanMs == null) {
    return errorResult(
      'Pass at least one of `sessionId` or `olderThanMs` — refusing to purge '
      'every body in the DB.',
    );
  }

  if (!confirm) {
    return jsonResult({
      'dryRun': true,
      'sessionId': sessionId,
      'olderThanMs': olderThanMs,
      'message': 'Pass confirm:true to actually purge.',
    });
  }

  try {
    final purged = CapturesDao().purgeBodies(
      sessionId: sessionId,
      olderThanMs: olderThanMs,
    );
    return jsonResult({
      'purgedBodies': purged,
      'sessionId': sessionId,
      'olderThanMs': olderThanMs,
    });
  } catch (e) {
    return errorResult('bodies_purge failed: $e');
  }
}
