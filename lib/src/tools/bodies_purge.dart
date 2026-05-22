import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../storage/captures_db.dart';
import 'result.dart';

final bodiesPurgeTool = Tool(
  name: 'bodies_purge',
  description:
      'Drops captured request/response BLOBs while preserving http_requests '
      'summary metadata. Useful to shrink the DB without losing the trace '
      'of what happened. Pass `sessionId` for a single session, '
      '`olderThanMs` to purge across sessions, or both. Default is dry-run; '
      'pass `confirm:true` to actually delete.',
  inputSchema: Schema.object(
    properties: {
      'sessionId': Schema.int(description: 'Restrict to a session id.'),
      'olderThanMs': Schema.int(
        description:
            'Millis-since-epoch. Bodies of requests whose start time is older '
            'than this are purged.',
      ),
      'confirm': Schema.bool(
        description: 'Required true to actually purge. Default false (dry-run reports what would go).',
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
      'Pass at least one of `sessionId` or `olderThanMs` — refusing to purge every body in the DB.',
      extra: const {
        'nextSteps': [
          'session_list — find sessionId(s) worth purging',
          'bodies_purge sessionId:<n> — purge one session',
          'bodies_purge olderThanMs:<epoch_ms> confirm:true — purge across sessions older than a date',
        ],
      },
    );
  }

  try {
    final dao = CapturesDao();
    final counts = dao.countPurgeableBodies(sessionId: sessionId, olderThanMs: olderThanMs);
    final rowCount = counts['rowCount'] ?? 0;
    final totalBytes = counts['totalBytes'] ?? 0;
    final totalMb = (totalBytes / (1024 * 1024)).toStringAsFixed(2);

    if (!confirm) {
      return jsonResult({
        'summary': rowCount == 0
            ? 'DRY-RUN — nothing to purge matching filters.'
            : 'DRY-RUN — would purge $rowCount body BLOB(s) totaling $totalMb MB. Cannot be undone.',
        'dryRun': true,
        'sessionId': sessionId,
        'olderThanMs': olderThanMs,
        'wouldPurgeRows': rowCount,
        'wouldPurgeBytes': totalBytes,
        'nextSteps': [
          if (rowCount == 0)
            'Widen the filter — increase olderThanMs or drop sessionId'
          else
            'bodies_purge ${sessionId != null ? "sessionId:$sessionId " : ""}${olderThanMs != null ? "olderThanMs:$olderThanMs " : ""}confirm:true — execute',
        ],
      });
    }

    final purged = dao.purgeBodies(sessionId: sessionId, olderThanMs: olderThanMs);
    return jsonResult({
      'summary': purged == 0
          ? 'No bodies matched filters — nothing purged.'
          : 'Purged $purged body BLOB(s) (~$totalMb MB). Metadata in http_requests is preserved.',
      'purgedBodies': purged,
      'purgedBytes': totalBytes,
      'sessionId': sessionId,
      'olderThanMs': olderThanMs,
      'warnings': const [
        'Disk space is NOT reclaimed yet — run db_vacuum to compact the file.',
      ],
      'nextSteps': const [
        'db_vacuum — reclaim disk space',
        'db_stats — confirm the new size',
      ],
    });
  } catch (e) {
    return errorResult('bodies_purge failed: $e', extra: {
      'sessionId': sessionId,
      'olderThanMs': olderThanMs,
      'nextSteps': const [
        'db_stats — confirm DB health',
      ],
    });
  }
}
