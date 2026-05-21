import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../storage/captures_db.dart';
import 'result.dart';

final networkQueryTool = Tool(
  name: 'network_query',
  description:
      'Read-only SQL escape hatch against the captures database. Only single '
      'SELECT (or WITH...SELECT) statements are accepted. Hard-capped at 500 '
      'rows. Schema: sessions, http_requests, http_bodies, socket_events, '
      'log_records — see README.',
  inputSchema: Schema.object(
    properties: {
      'sql': Schema.string(description: 'A single SELECT statement.'),
    },
    required: ['sql'],
  ),
);

FutureOr<CallToolResult> networkQuery(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final sql = args['sql'] as String?;
  if (sql == null || sql.trim().isEmpty) {
    return errorResult('Missing required arg `sql`.');
  }
  try {
    final rows = CapturesDao().rawSelect(sql);
    return jsonResult({
      'rowCount': rows.length,
      'rows': rows,
    });
  } on ArgumentError catch (e) {
    return errorResult(e.message?.toString() ?? 'invalid SQL');
  } catch (e) {
    return errorResult('sql failed: $e');
  }
}
