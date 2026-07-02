import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../storage/captures_db.dart';
import '../util/filters.dart';
import 'error_kind.dart';
import 'result.dart';

const int _kMaxSessions = 8;
const int _kPerSessionHardMax = 500;
const int _kPairsHardMax = 100;

final networkCorrelateTool = Tool(
  name: 'network_correlate',
  description:
      'Find correlated HTTP requests across sessions (the typed version of '
      'network_query for the "webhook originator + receiver" pattern: one app '
      'sends a request carrying a shared id, another receives it). Requires '
      'explicit sessionIds (cross-session is intentional) and a pattern '
      'substring.',
  inputSchema: Schema.object(
    properties: {
      'sessionIds': Schema.list(
        description:
            'REQUIRED. Session ids to correlate across (from network_status '
            'or session_list). Cap 8.',
        items: Schema.int(),
      ),
      'pattern': Schema.string(
        description:
            'REQUIRED. Substring to match (a correlation id, shared URL '
            'fragment, error string).',
      ),
      'which': Schema.string(
        description: 'Match "url" | "request" | "response" | "any" (default).',
      ),
      'timeWindowMs': Schema.int(
        description:
            'Only return pairs whose start times are within this many ms of '
            'each other (try 1000-5000). Omit for all pairs.',
      ),
      'limit': Schema.int(
        description: 'Max pairs (default 20, cap 100), tightest first.',
      ),
      'perSessionLimit': Schema.int(
        description:
            'Max raw matches per session before pairing (default 100, cap 500).',
      ),
    },
    required: ['sessionIds', 'pattern'],
  ),
);

FutureOr<CallToolResult> networkCorrelate(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};

  final sessionsRaw = args['sessionIds'];
  if (sessionsRaw is! List || sessionsRaw.isEmpty) {
    return errorResult(
      'Missing or invalid `sessionIds` — must be a non-empty list of ints.',
      kind: ErrorKind.badArgument,
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
        kind: ErrorKind.badArgument,
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
      kind: ErrorKind.badArgument,
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
        kind: ErrorKind.badArgument,
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
      kind: ErrorKind.badArgument,
      extra: const {
        'nextSteps': ['Retry with which:"any" (the default)'],
      },
    );
  }

  final timeWindowMs = args['timeWindowMs'] as int?;
  if (timeWindowMs != null && timeWindowMs < 0) {
    return errorResult(
      '`timeWindowMs` must be >= 0.',
      kind: ErrorKind.badArgument,
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

  final List<Map<String, Object?>> allMatches;
  try {
    allMatches = CapturesDao().correlateAcrossSessions(
      sessionIds: sessionIds,
      pattern: pattern,
      which: whichArg,
      perSessionLimit: perSessionLimit,
    );
  } catch (e) {
    return errorResult('network_correlate failed: $e', kind: ErrorKind.badQuery, extra: {
      'sessionIds': sessionIds,
      'pattern': pattern,
      'nextSteps': const [
        'Simplify the pattern (avoid raw FTS5 operators)',
        'network_query — fall back to SQL for ad-hoc cross-session work',
      ],
    });
  }

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
    } else if (n > 10) {
      // D8: sessions[].matches is a compact preview of the first 10; the
      // full set drives pair-finding but is not dumped.
      warnings.add(
        'Session $sid has $n matches; sessions[] previews the first 10 '
        '(compact). The `pairs` array carries the correlated matches with '
        'snippets.',
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

  // D8 (audit RC/F24): the flood was `sessions[].matches` dumping every
  // per-session match (up to perSessionLimit=100 each) with full snippets
  // — thousands of tokens for a zero-pair answer. Snippets belong on the
  // tight `pairs`; here emit a compact, capped preview and report the real
  // count so the agent knows what was elided.
  const displayCap = 10;
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
          'matchesTotal': perSessionMatches[sid]!.length,
          'matchesShown':
              perSessionMatches[sid]!.length.clamp(0, displayCap),
          'matches': [
            for (final m in perSessionMatches[sid]!.take(displayCap))
              {
                'id': m['id'],
                if (m['method'] != null) 'method': m['method'],
                if (m['url'] != null) 'url': m['url'],
                if (m['statusCode'] != null) 'statusCode': m['statusCode'],
                if (m['startTimeMs'] != null) 'startTimeMs': m['startTimeMs'],
              },
          ],
        },
    ],
    'pairs': cappedPairs,
    if (warnings.isNotEmpty) 'warnings': warnings,
    'nextSteps': nextSteps,
  });
}
