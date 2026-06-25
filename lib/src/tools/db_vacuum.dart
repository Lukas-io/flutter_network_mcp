import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../storage/captures_db.dart';
import 'error_kind.dart';
import 'result.dart';

final dbVacuumTool = Tool(
  name: 'db_vacuum',
  description:
      'Checkpoints the WAL, vacuums the captures DB, and runs PRAGMA '
      'optimize. Run after bulk deletions (session_delete, bodies_purge, '
      'alerts_clear) to actually shrink the file on disk.',
  inputSchema: Schema.object(properties: {}),
);

FutureOr<CallToolResult> dbVacuum(CallToolRequest request) async {
  try {
    final dao = CapturesDao();
    final before = dao.stats();
    final beforeBytes = (before['sizeBytes'] as int?) ?? 0;
    dao.vacuum();
    final after = dao.stats();
    final afterBytes = (after['sizeBytes'] as int?) ?? 0;
    final reclaimed = beforeBytes - afterBytes;
    final reclaimedMb = (reclaimed / (1024 * 1024)).toStringAsFixed(2);

    final summary = reclaimed > 0
        ? 'Vacuumed: ${before['sizeMb']} MB → ${after['sizeMb']} MB ($reclaimedMb MB reclaimed).'
        : 'Vacuumed: ${before['sizeMb']} MB → ${after['sizeMb']} MB (no space to reclaim — DB already compact).';

    final warnings = <String>[];
    if (reclaimed == 0) {
      warnings.add(
        'No space reclaimed. If you expected shrinkage, run session_delete or bodies_purge first.',
      );
    }

    return jsonResult({
      'summary': summary,
      'vacuumed': true,
      'beforeBytes': beforeBytes,
      'afterBytes': afterBytes,
      'reclaimedBytes': reclaimed,
      'beforeMb': before['sizeMb'],
      'afterMb': after['sizeMb'],
      if (warnings.isNotEmpty) 'warnings': warnings,
      'nextSteps': const [
        'db_stats — confirm the new size',
      ],
    });
  } catch (e) {
    return errorResult('db_vacuum failed: $e', kind: ErrorKind.internal, extra: const {
      'nextSteps': [
        'Confirm the DB is not locked by another process',
        'db_stats — check current state',
      ],
    });
  }
}
