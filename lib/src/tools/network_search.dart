import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../config/capabilities.dart';
import '../state/session.dart';
import '../storage/captures_db.dart';
import '../util/filters.dart';
import 'result.dart';

final networkSearchTool = Tool(
  name: 'network_search',
  description:
      'Find a captured request by something inside it — a URL substring, a '
      'body keyword, an error string from a stack trace. Use this when you '
      'remember WHAT the request contained but not which id it was. '
      'Searches URLs and (backfilled) request/response bodies; returns '
      'ranked matches with «highlighted» snippets. Hyphens / colons in the '
      'query work naturally. Cheaper than network_list when you have a '
      'concrete needle but no idea where in the haystack to look.',
  inputSchema: Schema.object(
    properties: {
      'query': Schema.string(
        description:
            'Text to search for. Phrase-quoted by default — pass operator '
            'syntax pre-escaped if you want AND/OR/NEAR semantics.',
      ),
      'sessionId': Schema.int(
        description: 'Restrict to a session id (default: current session).',
      ),
      'which': Schema.string(
        description:
            'Column to match: "url" | "request" | "response" | "any" (default).',
      ),
      'limit': Schema.int(
        description: 'Max results (default 20, hard cap 100). Ranked by BM25, lowest first.',
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
  final session = Session.instance;
  final sessionId = (args['sessionId'] as int?) ?? session.effectiveSessionId;
  final limit = clampLimit(args['limit'] as int?, fallback: 20, hardMax: 100);

  if (sessionId == null) {
    return errorResult(
      'No session — attach or open one first.',
      extra: const {
        'nextSteps': [
          'network_attach — connect to a live app',
          'session_open id:<n> — view a past session',
          'session_list — see what past sessions exist',
        ],
      },
    );
  }

  try {
    final rows = CapturesDao().searchRequests(
      query: query,
      sessionId: sessionId,
      which: whichArg,
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
      'sessionId': sessionId,
      'summary': summary,
      'query': query,
      'which': whichArg,
      'count': matches.length,
      'matches': matches,
      if (warnings.isNotEmpty) 'warnings': warnings,
      'nextSteps': nextSteps,
    });
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
