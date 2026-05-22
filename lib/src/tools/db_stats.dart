import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../storage/captures_db.dart';
import '../storage/database.dart';
import 'result.dart';

final dbStatsTool = Tool(
  name: 'db_stats',
  description:
      'Reports captures DB statistics: per-table row counts, total file '
      'size, body BLOB size, journal mode, pending-alert count, and the DB '
      'file path. Use when the file might be getting big.',
  inputSchema: Schema.object(properties: {}),
);

FutureOr<CallToolResult> dbStats(CallToolRequest request) async {
  try {
    final stats = CapturesDao().stats();
    return jsonResult({
      'path': CapturesDatabase.instance.path,
      ...stats,
    });
  } catch (e) {
    return errorResult('db_stats failed: $e');
  }
}
