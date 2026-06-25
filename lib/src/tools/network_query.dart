import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../storage/captures_db.dart';
import 'error_kind.dart';
import 'result.dart';

const int _kRowCap = 500;

final networkQueryTool = Tool(
  name: 'network_query',
  description:
      'Read-only SELECT against the captures DB for what the typed tools '
      'cannot express (cross-session aggregates, percentile timings, joins, '
      'top error URLs). Single statement, 500-row cap; BLOB cells return '
      '{type:"blob",size}. Schema in docs/tools/power/network_query.md. Prefer '
      'the typed tools first.',
  inputSchema: Schema.object(
    properties: {
      'sql': Schema.string(
        description: 'A single SELECT / WITH...SELECT (no semicolons).',
      ),
    },
    required: ['sql'],
  ),
);

FutureOr<CallToolResult> networkQuery(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final sql = args['sql'] as String?;
  if (sql == null || sql.trim().isEmpty) {
    return errorResult('Missing required arg `sql`.',
        kind: ErrorKind.badArgument,
        extra: const {
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
    return errorResult(e.message?.toString() ?? 'invalid SQL',
        kind: ErrorKind.badQuery,
        extra: const {
          'nextSteps': [
            'Only single SELECT / WITH...SELECT statements are allowed',
            'Remove trailing semicolons; chain via subqueries instead',
          ],
        });
  } catch (e) {
    // Self-correct: return the schema inline so the agent fixes the query on
    // its next call rather than guessing column names or looping (telemetry:
    // network_query has a real error rate and a query->query self-loop).
    Map<String, List<String>>? schema;
    try {
      schema = CapturesDao().schemaDigest();
    } catch (_) {/* schema lookup is best-effort */}
    return errorResult('sql failed: $e',
        kind: ErrorKind.badQuery,
        extra: {
          if (schema != null) 'schema': schema,
          'nextSteps': const [
            'Fix table/column names using the `schema` map above, then retry',
            'Wrap aggregates in a subquery; no semicolons or multiple statements',
          ],
        });
  }
}
