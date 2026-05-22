import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../storage/captures_db.dart';
import 'result.dart';

final dbVacuumTool = Tool(
  name: 'db_vacuum',
  description:
      'Checkpoints the WAL, vacuums the captures DB, and runs PRAGMA optimize. '
      'Run after bulk deletions (session_delete, bodies_purge) to actually '
      'shrink the file on disk.',
  inputSchema: Schema.object(properties: {}),
);

FutureOr<CallToolResult> dbVacuum(CallToolRequest request) async {
  try {
    final dao = CapturesDao();
    final before = dao.stats();
    dao.vacuum();
    final after = dao.stats();
    return jsonResult({
      'vacuumed': true,
      'beforeBytes': before['sizeBytes'],
      'afterBytes': after['sizeBytes'],
      'beforeMb': before['sizeMb'],
      'afterMb': after['sizeMb'],
    });
  } catch (e) {
    return errorResult('db_vacuum failed: $e');
  }
}
