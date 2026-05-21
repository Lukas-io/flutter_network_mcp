import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../storage/captures_db.dart';
import '../util/filters.dart';
import 'result.dart';

final networkSearchTool = Tool(
  name: 'network_search',
  description:
      'Full-text search across captured HTTP urls + request/response bodies '
      'using SQLite FTS5. Returns ranked matches with a short snippet. '
      'Defaults to the current session (live or viewed).',
  inputSchema: Schema.object(
    properties: {
      'query': Schema.string(
        description: 'FTS5 MATCH query. Supports phrase quoting and AND/OR/NOT.',
      ),
      'sessionId': Schema.int(
        description: 'Restrict to a session. Default: current session.',
      ),
      'which': Schema.string(
        description:
            'Column to match: "url", "request", "response", or "any" (default).',
      ),
      'limit': Schema.int(description: 'Max results (default 20, hard cap 100).'),
    },
    required: ['query'],
  ),
);

FutureOr<CallToolResult> networkSearch(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final query = args['query'] as String?;
  if (query == null || query.trim().isEmpty) {
    return errorResult('Missing required arg `query`.');
  }
  final whichArg = (args['which'] as String?) ?? 'any';
  if (!['url', 'request', 'response', 'any'].contains(whichArg)) {
    return errorResult('`which` must be url, request, response, or any.');
  }
  final session = Session.instance;
  final sessionId = (args['sessionId'] as int?) ?? session.effectiveSessionId;
  final limit = clampLimit(args['limit'] as int?, fallback: 20, hardMax: 100);

  try {
    final rows = CapturesDao().searchRequests(
      query: query,
      sessionId: sessionId,
      which: whichArg,
      limit: limit,
    );
    return jsonResult({
      'sessionId': sessionId,
      'query': query,
      'which': whichArg,
      'count': rows.length,
      'matches': [
        for (final r in rows)
          {
            'sessionId': r['session_id'],
            'id': r['vm_id'],
            'method': r['method'],
            'url': r['url'],
            'statusCode': r['status_code'],
            'snippet': r['snippet'],
            'rank': r['rank'],
          },
      ],
    });
  } catch (e) {
    return errorResult('network_search failed: $e');
  }
}
