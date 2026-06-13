import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../config/capabilities.dart';
import '../storage/captures_db.dart';
import '../util/filters.dart';
import '../util/scope.dart';
import 'result.dart';

final networkSearchTool = Tool(
  name: 'network_search',
  description:
      'Find a captured request by content (URL substring, body keyword, '
      'error string) when you know what it contained but not the id. '
      'BM25-ranked, with highlighted snippets. Searches URLs and backfilled '
      'request/response bodies.',
  inputSchema: Schema.object(
    properties: {
      'query': Schema.string(
        description: 'Text to search for; phrase-matched by default.',
      ),
      'sessionId': Schema.int(
        description:
            'Session to read from. Omit to auto-resolve (the sole attached '
            'session, or the one you opened).',
      ),
      'appNameContains': Schema.string(
        description: 'Pick the session by app-name substring instead of sessionId.',
      ),
      'isolateId': Schema.string(
        description:
            'Restrict to one isolate (id from network_status). Omit to search '
            'all isolates.',
      ),
      'which': Schema.string(
        description: 'Match "url" | "request" | "response" | "any" (default).',
      ),
      'limit': Schema.int(
        description: 'Max results (default 20, cap 100).',
      ),
    },
    required: ['query'],
  ),
);

FutureOr<CallToolResult> networkSearch(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final caps = CapabilityConfig.instance;
  final query = args['query'] as String?;
  if (query == null || query.trim().isEmpty) {
    return errorResult('Missing required arg `query`.', extra: const {
      'nextSteps': [
        'Retry with a non-empty query string',
        'network_list — fallback if you only need metadata filtering',
      ],
    });
  }
  final whichArg = (args['which'] as String?) ?? 'any';
  if (!['url', 'request', 'response', 'any'].contains(whichArg)) {
    return errorResult('`which` must be url, request, response, or any.', extra: const {
      'nextSteps': ['Retry with which:"any" (default)'],
    });
  }
  final (scope, scopeErr) = resolveScope(args);
  if (scopeErr != null) return scopeErr;
  scope!;
  final sessionId = scope.sessionId;
  final isolateId = args['isolateId'] as String?;
  final limit = clampLimit(args['limit'] as int?, fallback: 20, hardMax: 100);

  try {
    final rows = CapturesDao().searchRequests(
      query: query,
      sessionId: sessionId,
      which: whichArg,
      isolateId: isolateId,
      limit: limit,
    );

    final matches = <Map<String, Object?>>[];
    for (final r in rows) {
      matches.add({
        'sessionId': r['session_id'],
        'id': r['vm_id'],
        if (r['method'] != null) 'method': r['method'],
        if (r['url'] != null) 'url': r['url'],
        if (r['status_code'] != null) 'statusCode': r['status_code'],
        if (r['snippet'] != null) 'snippet': r['snippet'],
        if (r['rank'] != null) 'rank': r['rank'],
      });
    }

    final summary = matches.isEmpty
        ? 'No matches for "$query" in session $sessionId (which=$whichArg).'
        : '${matches.length} match(es) for "$query" in session $sessionId (ranked by BM25).';

    final warnings = <String>[];
    if (matches.isEmpty) {
      warnings.add(
        'No matches. Bodies may not be indexed yet (writer backfills every ~2s) or the query is too specific.',
      );
    }

    final nextSteps = <String>[];
    if (matches.isNotEmpty) {
      nextSteps.add('network_get id:"${matches.first['id']}" — full headers + body for the top match');
      if (matches.length > 1 && caps.isEnabled(Category.http)) {
        nextSteps.add('network_diff idA:"${matches.first['id']}" idB:"${matches[1]['id']}" — compare the top two');
      }
    } else {
      nextSteps.add('Retry with a shorter substring or which:"any"');
      nextSteps.add('network_list — browse by metadata instead');
    }

    return jsonResult({
      'scope': scope.toBlock(),
      'sessionId': sessionId,
      'summary': summary,
      'query': query,
      'which': whichArg,
      'count': matches.length,
      'matches': matches,
      if (warnings.isNotEmpty) 'warnings': warnings,
      'nextSteps': nextSteps,
    }, scopeSessionId: scope.sessionId);
  } catch (e) {
    return errorResult('network_search failed: $e', extra: {
      'sessionId': sessionId,
      'query': query,
      'nextSteps': const [
        'Simplify the query (avoid raw FTS5 operators)',
        'network_list — fall back to metadata filtering',
      ],
    });
  }
}
