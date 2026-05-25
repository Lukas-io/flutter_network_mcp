import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../config/capabilities.dart';
import '../storage/captures_db.dart';
import '../storage/database.dart';
import 'result.dart';

const int _kWarnSizeMb = 100;
const double _kBodiesHeavyRatio = 0.7;

final dbStatsTool = Tool(
  name: 'db_stats',
  description:
      'Check on the captures DB — file size on disk, per-table row counts, '
      'body BLOB bytes, pending-alert count, journal mode, file path. Use '
      'when the DB might be getting big (run this before `db_vacuum` so '
      'you know whether vacuum will actually reclaim much), when '
      'investigating which tables have grown most, or just to see where '
      'on disk your captures live.',
  inputSchema: Schema.object(properties: {}),
);

FutureOr<CallToolResult> dbStats(CallToolRequest request) async {
  final caps = CapabilityConfig.instance;
  try {
    final stats = CapturesDao().stats();
    final sizeBytes = (stats['sizeBytes'] as int?) ?? 0;
    final bodiesBytes = (stats['bodiesBytes'] as int?) ?? 0;
    final sizeMb = sizeBytes / (1024 * 1024);
    final sessionCount = ((stats['rowCounts'] as Map?)?['sessions'] as int?) ?? 0;
    final pendingAlerts = (stats['pendingAlerts'] as int?) ?? 0;
    final bodyRatio = sizeBytes == 0 ? 0.0 : bodiesBytes / sizeBytes;

    final summary = 'DB at ${stats['sizeMb']} MB across $sessionCount session(s) '
        '(${stats['bodiesMb']} MB in bodies, $pendingAlerts undrained alert(s)).';

    final warnings = <String>[];
    if (sizeMb > _kWarnSizeMb) {
      warnings.add(
        'DB is ${stats['sizeMb']} MB — consider bodies_purge / session_delete + db_vacuum to shrink.',
      );
    }
    if (bodyRatio > _kBodiesHeavyRatio && bodiesBytes > 5 * 1024 * 1024) {
      warnings.add(
        'Bodies are ${(bodyRatio * 100).toStringAsFixed(0)}% of the DB — bodies_purge is the highest-impact cleanup.',
      );
    }
    if (sessionCount >= 50) {
      warnings.add('Many sessions ($sessionCount) — old ones may be ready for session_delete.');
    }

    final nextSteps = <String>[];
    if (caps.isEnabled(Category.sessions)) {
      nextSteps.add('session_list — see which sessions are eating space');
    }
    if (sizeMb > _kWarnSizeMb || bodyRatio > _kBodiesHeavyRatio) {
      if (caps.isEnabled(Category.admin)) {
        nextSteps.add('bodies_purge sessionId:<n> confirm:true — drop large BLOBs');
        nextSteps.add('db_vacuum — reclaim disk space after deletes');
      }
    }
    if (pendingAlerts > 0 && caps.isEnabled(Category.alerts)) {
      nextSteps.add('alerts_drain — handle the $pendingAlerts pending alert(s)');
    }
    if (nextSteps.isEmpty) {
      nextSteps.add('No action needed — DB is healthy.');
    }

    return jsonResult({
      'summary': summary,
      'path': CapturesDatabase.instance.path,
      ...stats,
      if (warnings.isNotEmpty) 'warnings': warnings,
      'nextSteps': nextSteps,
    });
  } catch (e) {
    return errorResult('db_stats failed: $e', extra: const {
      'nextSteps': [
        'Confirm the DB is open (server started with --data-dir or default)',
      ],
    });
  }
}
