import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../storage/captures_db.dart';
import 'result.dart';

const int _kRowCap = 500;

final networkQueryTool = Tool(
  name: 'network_query',
  description:
      'Run a custom SELECT against the captures DB when the typed tools '
      'can\'t express what you need: cross-session aggregates, slowest '
      'endpoints by host, percentile timings, joins between requests and '
      'alerts, top error URLs. Schema lives in '
      'docs/tools/power/network_query.md. Single statement, read-only, '
      '500-row cap. BLOB cells (http_bodies.bytes) return '
      '`{type:"blob", size}` so they don\'t flood context; oversized strings '
      'truncate. Reach for this AFTER you\'ve confirmed network_list / '
      'network_search / session_list can\'t answer the question — those are '
      'cheaper and don\'t need SQL.',
  inputSchema: Schema.object(
    properties: {
      'sql': Schema.string(
        description:
            'A single SELECT / WITH...SELECT. Semicolons not allowed (one '
            'statement only).',
      ),
    },
    required: ['sql'],
  ),
);

FutureOr<CallToolResult> networkQuery(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final sql = args['sql'] as String?;
  if (sql == null || sql.trim().isEmpty) {
    return errorResult('Missing required arg `sql`.', extra: const {
      'nextSteps': [
        'Retry with sql:"SELECT COUNT(*) FROM sessions"',
        'session_list / network_list — try the structured tools first',
      ],
    });
  }

  try {
    final rows = CapturesDao().rawSelect(sql);
    final rowCount = rows.length;
    final hitCap = rowCount >= _kRowCap;
    final hasBlobs = rows.any((r) => r.values.any((v) => v is Map && v['type'] == 'blob'));

    final summary = rowCount == 0
        ? 'Query returned no rows.'
        : '$rowCount row(s) returned'
            '${hitCap ? " (hit hard cap of $_kRowCap — query may have more)" : ""}'
            '${hasBlobs ? "; BLOB cells summarized" : ""}.';

    final warnings = <String>[];
    if (hitCap) {
      warnings.add(
        'Result hit the $_kRowCap-row cap. Add LIMIT, WHERE filters, or use GROUP BY for a summary.',
      );
    }
    if (hasBlobs) {
      warnings.add(
        'BLOB columns (e.g. http_bodies.bytes) returned as `{type:"blob",size}` — use network_body or network_get to read body content.',
      );
    }

    return jsonResult({
      'summary': summary,
      'rowCount': rowCount,
      if (warnings.isNotEmpty) 'warnings': warnings,
      'nextSteps': const [
        'For HTTP bodies: network_body id:<vm_id> which:response',
        'For session details: session_open id:<n>',
      ],
      'rows': rows,
    });
  } on ArgumentError catch (e) {
    return errorResult(e.message?.toString() ?? 'invalid SQL', extra: const {
      'nextSteps': [
        'Only single SELECT / WITH...SELECT statements are allowed',
        'Remove trailing semicolons; chain via subqueries instead',
      ],
    });
  } catch (e) {
    return errorResult('sql failed: $e', extra: const {
      'nextSteps': [
        'Verify table/column names against the schema (see network_query tool description)',
        'Try SELECT name FROM sqlite_schema WHERE type=\'table\' to list tables',
      ],
    });
  }
}
