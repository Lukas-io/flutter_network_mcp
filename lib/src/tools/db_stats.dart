import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../config/capabilities.dart';
import '../config/db_cap_config.dart';
import '../storage/captures_db.dart';
import '../storage/database.dart';
import '../storage/db_cap.dart';
import 'error_kind.dart';
import 'result.dart';

const int _kWarnSizeMb = 100;
const double _kBodiesHeavyRatio = 0.7;

final dbStatsTool = Tool(
  name: 'db_stats',
  description:
      'Inspect the captures DB: file size, per-table row counts, body BLOB '
      'bytes, pending alerts, journal mode, path. Run before db_vacuum to see '
      'if it will reclaim much.',
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
    // #58: rolling cap is self-managing, so only nudge manual cleanup when it
    // is turned OFF. When on, the watchdog handles growth; just report it.
    final capBytes = DbCapConfig.maxBytes;
    if (capBytes == null && sessionCount >= 50) {
      warnings.add('Many sessions ($sessionCount) and the rolling cap is OFF — old ones may be ready for session_delete.');
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

    final lastEviction = DbCapManager.instance.lastEviction;
    final ephemeral = CapturesDatabase.instance.isEphemeral;
    return jsonResult({
      'summary': ephemeral ? '$summary (NO-PERSIST: in-memory only)' : summary,
      'path': CapturesDatabase.instance.path,
      'ephemeral': ephemeral,
      ...stats,
      'sizeCap': {
        'enabled': capBytes != null,
        if (capBytes != null) 'maxBytes': capBytes,
        if (capBytes != null) 'maxMb': (capBytes / (1024 * 1024)).toStringAsFixed(0),
        'env': 'FLUTTER_NETWORK_MCP_MAX_DB_BYTES (0/off disables)',
      },
      if (lastEviction != null) 'lastEviction': lastEviction,
      if (warnings.isNotEmpty) 'warnings': warnings,
      'nextSteps': nextSteps,
    });
  } catch (e) {
    return errorResult('db_stats failed: $e', kind: ErrorKind.internal, extra: const {
      'nextSteps': [
        'Confirm the DB is open (server started with --data-dir or default)',
      ],
    });
  }
}
