import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../storage/captures_db.dart';
import '../util/filters.dart';
import 'result.dart';

const int _kMaxSessions = 8;
const int _kPerSessionHardMax = 500;
const int _kPairsHardMax = 100;

final networkCorrelateTool = Tool(
  name: 'network_correlate',
  description:
      'Find correlated HTTP requests across multiple captured sessions — '
      'the typed companion to network_query SQL for the common '
      '"webhook originator + receiver" pattern. Example: sanga_mobile '
      'sends POST /webhook/order with body containing "txn-abc-123"; '
      'sanga_driver receives POST /handlers/webhook a few hundred ms '
      'later with the same id in its body. `network_correlate` finds '
      'both halves in one call.\n\n'
      '**Required:** `sessionIds:[int]` (explicit, no auto-resolve — '
      'cross-session aggregation is intentional, the agent must pick '
      'which apps to compare) and `pattern:string` (substring searched '
      'via FTS5 in URLs and/or bodies). **Optional:** `timeWindowMs` to '
      'only return pairs whose start times fall within that window of '
      'each other; `which` to scope to url / request / response only. '
      'Hard caps: 8 sessions per call, 100 pair results, 500 raw matches '
      'per session.',
  inputSchema: Schema.object(
    properties: {
      'sessionIds': Schema.list(
        description:
            'REQUIRED — list of session ids to correlate across. Get them '
            'from network_status.attached[].sessionId or session_list. '
            'Hard cap of 8 sessions per call (cross-session aggregation '
            'is bounded by design — use network_query for wider sweeps).',
        items: Schema.int(),
      ),
      'pattern': Schema.string(
        description:
            'REQUIRED — substring to search for (a correlation id, a '
            'shared URL fragment, an error string). Phrase-quoted in '
            'FTS5 so hyphens / colons / special chars work naturally.',
      ),
      'which': Schema.string(
        description:
            'Column to match: "url" | "request" | "response" | "any" '
            '(default). Use "response" to chase responses containing an '
            'error id; "request" to chase shared body fields; "url" for '
            'matching path fragments.',
      ),
      'timeWindowMs': Schema.int(
        description:
            'Optional — only return pairs whose start times fall within '
            'this many milliseconds of each other. Useful for tight '
            'request → webhook pairs (try 1000–5000ms). Omit to return '
            'every pair regardless of timing.',
      ),
      'limit': Schema.int(
        description:
            'Max pairs returned (default 20, hard cap 100). Pairs are '
            'sorted by smallest time delta first (tightest pairs at the '
            'top). Per-session match cap is separate (perSessionLimit).',
      ),
      'perSessionLimit': Schema.int(
        description:
            'Max raw matches per session BEFORE pairing (default 100, '
            'hard cap 500). Bounds memory + context regardless of pattern '
            'noisiness — a single noisy session can\'t drown the others.',
      ),
    },
    required: ['sessionIds', 'pattern'],
  ),
);

FutureOr<CallToolResult> networkCorrelate(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};

  // Parse + validate sessionIds.
  final sessionsRaw = args['sessionIds'];
  if (sessionsRaw is! List || sessionsRaw.isEmpty) {
    return errorResult(
      'Missing or invalid `sessionIds` — must be a non-empty list of ints.',
      extra: const {
        'nextSteps': [
          'network_status — list currently-attached session ids',
          'session_list — see historical session ids',
          'network_correlate sessionIds:[14,15] pattern:"..." — retry',
        ],
      },
    );
  }
  final sessionIds = <int>[];
  for (final v in sessionsRaw) {
    if (v is! int) {
      return errorResult(
        'sessionIds must contain only integers; got `${v.runtimeType}`.',
        extra: const {
          'nextSteps': [
            'Retry with sessionIds:[14,15] — integers, not strings',
          ],
        },
      );
    }
    if (!sessionIds.contains(v)) sessionIds.add(v);
  }
  if (sessionIds.length > _kMaxSessions) {
    return errorResult(
      'Too many sessionIds (${sessionIds.length}); hard cap is '
      '$_kMaxSessions per call. Pick the most relevant subset, or use '
      'network_query for unrestricted SQL.',
      extra: {
        'sessionIdsRequested': sessionIds,
        'cap': _kMaxSessions,
        'nextSteps': const [
          'Drop some sessionIds and retry',
          'network_query — write your own SQL for wider cross-session sweeps',
        ],
      },
    );
  }

  final pattern = args['pattern'] as String?;
  if (pattern == null || pattern.trim().isEmpty) {
    return errorResult('Missing or empty `pattern` — must be a non-empty string.',
        extra: const {
      'nextSteps': [
        'Retry with pattern:"<correlation id or substring>"',
      ],
    });
  }

  final whichArg = (args['which'] as String?) ?? 'any';
  if (!const {'url', 'request', 'response', 'any'}.contains(whichArg)) {
    return errorResult(
      '`which` must be one of: url | request | response | any.',
      extra: const {
        'nextSteps': ['Retry with which:"any" (the default)'],
      },
    );
  }

  final timeWindowMs = args['timeWindowMs'] as int?;
  if (timeWindowMs != null && timeWindowMs < 0) {
    return errorResult(
      '`timeWindowMs` must be >= 0.',
      extra: const {
        'nextSteps': ['Omit timeWindowMs for no window, or pass a positive int'],
      },
    );
  }

  final limit = clampLimit(args['limit'] as int?, fallback: 20, hardMax: _kPairsHardMax);
  final perSessionLimit = clampLimit(
    args['perSessionLimit'] as int?,
    fallback: 100,
    hardMax: _kPerSessionHardMax,
  );

  // Run the FTS5 query for each session.
  final List<Map<String, Object?>> allMatches;
  try {
    allMatches = CapturesDao().correlateAcrossSessions(
      sessionIds: sessionIds,
      pattern: pattern,
      which: whichArg,
      perSessionLimit: perSessionLimit,
    );
  } catch (e) {
    return errorResult('network_correlate failed: $e', extra: {
      'sessionIds': sessionIds,
      'pattern': pattern,
      'nextSteps': const [
        'Simplify the pattern (avoid raw FTS5 operators)',
        'network_query — fall back to SQL for ad-hoc cross-session work',
      ],
    });
  }

  // Group matches by session + tag with appName from the registry when
  // the session is currently attached.
  final registry = SessionRegistry.instance;
  final perSessionMatches = <int, List<Map<String, Object?>>>{
    for (final sid in sessionIds) sid: [],
  };
  final perSessionAppName = <int, String?>{
    for (final sid in sessionIds) sid: registry.attachedById(sid)?.appName,
  };
  for (final row in allMatches) {
    final sid = row['session_id'] as int;
    final startUs = row['start_us'] as int?;
    perSessionMatches[sid]!.add({
      'sessionId': sid,
      if (perSessionAppName[sid] != null) 'appName': perSessionAppName[sid],
      'id': row['vm_id'],
      if (row['isolate_id'] != null) 'isolateId': row['isolate_id'],
      if (row['method'] != null) 'method': row['method'],
      if (row['url'] != null) 'url': row['url'],
      if (row['status_code'] != null) 'statusCode': row['status_code'],
      if (startUs != null) 'startTimeMs': startUs ~/ 1000,
      if (row['snippet'] != null) 'snippet': row['snippet'],
    });
  }
  final totalMatches = allMatches.length;

  // Build cross-session pairs. Tightest time delta first.
  // For >2 sessions, every unordered pair of sessions contributes its own
  // cross-product. This stays bounded by the per-session cap × pair-of-
  // sessions count, and the hard `limit` ceiling.
  final pairs = <Map<String, Object?>>[];
  for (int i = 0; i < sessionIds.length; i++) {
    for (int j = i + 1; j < sessionIds.length; j++) {
      final sidA = sessionIds[i];
      final sidB = sessionIds[j];
      for (final reqA in perSessionMatches[sidA]!) {
        final tA = reqA['startTimeMs'] as int?;
        if (tA == null) continue;
        for (final reqB in perSessionMatches[sidB]!) {
          final tB = reqB['startTimeMs'] as int?;
          if (tB == null) continue;
          final delta = (tA - tB).abs();
          if (timeWindowMs != null && delta > timeWindowMs) continue;
          pairs.add({
            'match': pattern,
            'spanMs': delta,
            'requests': [reqA, reqB],
          });
        }
      }
    }
  }
  pairs.sort((a, b) => (a['spanMs'] as int).compareTo(b['spanMs'] as int));
  final cappedPairs = pairs.take(limit).toList();

  final warnings = <String>[];
  if (totalMatches == 0) {
    warnings.add(
      'No matches for "$pattern" in any of the named sessions. The pattern '
      'may not exist, or the writer may not have backfilled bodies yet '
      '(FTS5 indexing happens during the 2s body backfill tick).',
    );
  }
  for (final sid in sessionIds) {
    final n = perSessionMatches[sid]!.length;
    if (n == perSessionLimit) {
      warnings.add(
        'Session $sid hit the perSessionLimit ($perSessionLimit) — there '
        'may be more matches not shown. Raise perSessionLimit or narrow '
        'the pattern.',
      );
    }
  }
  if (pairs.length > limit) {
    warnings.add(
      '${pairs.length} candidate pairs found; only the tightest $limit '
      'are returned. Raise `limit` or use `timeWindowMs` to narrow.',
    );
  }
  if (sessionIds.length == 1) {
    warnings.add(
      'Only one sessionId given — `pairs` will be empty. Use '
      'network_search for single-session content matching instead.',
    );
  }

  final summary = totalMatches == 0
      ? 'No matches for "$pattern" across sessions ${sessionIds.join(", ")}.'
      : 'Found $totalMatches matched request(s) across sessions '
          '${sessionIds.join(", ")}'
          '${cappedPairs.isNotEmpty ? ", ${cappedPairs.length} cross-session pair(s)" : ""}'
          '${timeWindowMs != null ? " within ${timeWindowMs}ms" : ""}.';

  final nextSteps = <String>[];
  if (cappedPairs.isNotEmpty) {
    final first = cappedPairs.first;
    final reqs = first['requests'] as List;
    final r0 = reqs[0] as Map;
    final r1 = reqs[1] as Map;
    nextSteps.add(
      'network_get sessionId:${r0['sessionId']} id:"${r0['id']}" — full '
      'detail on the originator (${first['spanMs']}ms before its pair)',
    );
    nextSteps.add(
      'network_get sessionId:${r1['sessionId']} id:"${r1['id']}" — full '
      'detail on the receiver',
    );
    if (cappedPairs.length > 1) {
      nextSteps.add(
        'network_correlate timeWindowMs:<smaller> — narrow if too many '
        'pairs (currently ${cappedPairs.length})',
      );
    }
  } else if (totalMatches > 0) {
    nextSteps.add(
      'Per-session matches present but no pairs within the time window. '
      'Try raising timeWindowMs, omitting it, or using which:"any".',
    );
  } else {
    nextSteps.add('Try a shorter pattern, or which:"any"');
    nextSteps.add('network_search — single-session FTS as a fallback');
  }

  return jsonResult({
    'scope': {'sessionIds': sessionIds},
    'pattern': pattern,
    'which': whichArg,
    if (timeWindowMs != null) 'timeWindowMs': timeWindowMs,
    'summary': summary,
    'totalMatches': totalMatches,
    'matchesPerSession': {
      for (final sid in sessionIds) sid.toString(): perSessionMatches[sid]!.length,
    },
    'sessions': [
      for (final sid in sessionIds)
        {
          'sessionId': sid,
          if (perSessionAppName[sid] != null) 'appName': perSessionAppName[sid],
          'matches': perSessionMatches[sid],
        },
    ],
    'pairs': cappedPairs,
    if (warnings.isNotEmpty) 'warnings': warnings,
    'nextSteps': nextSteps,
  });
}
