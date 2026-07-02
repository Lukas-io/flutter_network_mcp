import 'dart:async';

import 'package:dart_mcp/server.dart';
import 'package:vm_service/vm_service.dart' hide ErrorKind;

import '../config/capabilities.dart';
import '../config/session_filters.dart';
import '../state/session.dart';
import '../storage/captures_db.dart';
import '../util/body_decoder.dart';
import '../util/http_timing.dart';
import '../util/body_status.dart';
import '../util/filters.dart';
import '../util/scope.dart';
import '../util/token_budget.dart';
import 'error_kind.dart';
import 'result.dart';

final networkListTool = Tool(
  name: 'network_list',
  description:
      'Lists captured HTTP requests (newest-first, summaries only, no '
      'bodies). Live reads are incremental: each call returns only what is '
      'new since the last; pass since:0 for everything. After session_open, '
      'reads history.',
  inputSchema: Schema.object(
    properties: {
      'sessionId': Schema.int(
        description:
            'Session to read from. Omit to auto-resolve (the sole attached '
            'session, or the one you opened).',
      ),
      'appNameContains': Schema.string(
        description: 'Pick the session by app-name substring instead of sessionId.',
      ),
      'since': Schema.int(
        description:
            'Microsecond cursor. Omit for incremental (new since last call), '
            '0 for all captured. Pass a prior nextCursor to page.',
      ),
      'before': Schema.int(
        description:
            'History-mode cursor: only requests STARTED BEFORE this µs '
            'timestamp (newest-first, so this pages OLDER — pass a prior '
            'nextCursor). Ignored on live incremental reads.',
      ),
      'method': Schema.list(
        description: 'Filter by HTTP method(s), e.g. ["GET","POST"].',
        items: Schema.string(),
      ),
      'hostContains': Schema.string(
        description: 'Case-insensitive substring on the request host.',
      ),
      'statusMin': Schema.int(
        description: 'Min status code (e.g. 400 for errors).',
      ),
      'statusMax': Schema.int(
        description: 'Max status code.',
      ),
      'isolateId': Schema.string(
        description:
            'Restrict to one isolate (id from network_status). Omit to merge '
            'all isolates.',
      ),
      'limit': Schema.int(
        description: 'Max requests (default 50, cap 200).',
      ),
      'maxTokens': Schema.int(
        description:
            'Token budget for this response; trims the requests array '
            'newest-first to fit and reports budget.dropped. Overrides the '
            'session_configure maxResponseTokens default.',
      ),
    },
  ),
);

FutureOr<CallToolResult> networkList(CallToolRequest request) async {
  final caps = CapabilityConfig.instance;
  final args = request.arguments ?? const <String, Object?>{};
  final (scope, scopeErr) = resolveScope(args);
  if (scopeErr != null) return scopeErr;
  scope!;

  final sf = SessionFilters.instance;
  final sinceArg = args['since'] as int?;
  final beforeArg = args['before'] as int?;
  final methods =
      args.containsKey('method') ? readStringList(args['method']) : sf.method;
  final hostContains = args.containsKey('hostContains')
      ? args['hostContains'] as String?
      : sf.hostContains;
  final statusMin =
      args.containsKey('statusMin') ? args['statusMin'] as int? : sf.statusMin;
  final statusMax =
      args.containsKey('statusMax') ? args['statusMax'] as int? : sf.statusMax;
  final isolateFilter = args['isolateId'] as String?;
  final limit = clampLimit(args['limit'] as int?, fallback: 50, hardMax: 200);
  final maxTokens = args['maxTokens'] as int? ?? sf.maxResponseTokens;

  if (!scope.isLive || beforeArg != null) {
    // D4: `before:` pages OLDER, which only the DB has — serve it from the
    // history path even for a live session.
    return _historyList(
      scope,
      caps,
      sinceArg,
      beforeArg,
      methods,
      hostContains,
      statusMin,
      statusMax,
      isolateFilter,
      limit,
      maxTokens,
    );
  }

  final attached = SessionRegistry.instance.attachedById(scope.sessionId)!;
  final cursor = sinceArg == null
      ? attached.lastHttpCursor
      : (sinceArg <= 0 ? null : DateTime.fromMicrosecondsSinceEpoch(sinceArg));

  final isolateIds = isolateFilter == null
      ? [for (final iso in attached.vm.httpProfilingIsolates) iso.id]
      : [isolateFilter];

  try {
    final perIsolateRequests = <(HttpProfileRequest, String)>[];
    DateTime? latestCursor;
    int scannedTotal = 0;
    for (final isoId in isolateIds) {
      try {
        final profile = await attached.vm.getHttpProfileForIsolate(
          isoId,
          updatedSince: cursor,
        );
        if (latestCursor == null || profile.timestamp.isAfter(latestCursor)) {
          latestCursor = profile.timestamp;
        }
        scannedTotal += profile.requests.length;
        for (final req in profile.requests) {
          perIsolateRequests.add((req, isoId));
        }
      } catch (_) {/* per-isolate skip */}
    }
    if (latestCursor != null) {
      attached.lastHttpCursor = latestCursor;
    }

    perIsolateRequests
        .sort((a, b) => b.$1.startTime.compareTo(a.$1.startTime));

    final filtered = <Map<String, Object?>>[];
    var skippedErrors = 0;
    for (final (req, isoId) in perIsolateRequests) {
      try {
        if (!methodMatches(req.method, methods)) continue;
        if (!hostMatches(req.uri.toString(), hostContains)) continue;
        if (!statusInRange(req.response?.statusCode, statusMin, statusMax)) {
          continue;
        }
        final summary = liveSummary(req);
        summary['isolateId'] = isoId;
        filtered.add(summary);
        if (filtered.length >= limit) break;
      } catch (_) {
        skippedErrors++;
      }
    }

    final liveSid = scope.sessionId;
    final activeFilters =
        _activeFilters(methods, hostContains, statusMin, statusMax);
    final cursorWasIncremental = sinceArg == null && cursor != null;

    final budget = maxTokens;
    final budgetTrim = trimToTokenBudget(filtered, budget);
    final budgetDropped = budgetTrim.dropped;
    if (budgetDropped > 0) {
      filtered.removeRange(budgetTrim.kept.length, filtered.length);
    }

    final scopeLabel =
        'session $liveSid (live${scope.appName != null ? ", ${scope.appName}" : ""})';
    final summary = liveListSummary(
      matched: filtered.length,
      scannedTotal: scannedTotal,
      cursorAdvanced: cursor != null,
      incremental: cursorWasIncremental,
      scopeLabel: scopeLabel,
    );

    final warnings = <String>[];
    if (filtered.isEmpty && scannedTotal == 0 && cursor == null) {
      warnings.add(
        'Capture profile is empty. Drive the app to generate traffic, then re-call.',
      );
    } else if (filtered.isEmpty && scannedTotal > 0) {
      warnings.add(
        'Filters excluded all $scannedTotal captured request(s).',
      );
    }
    if (scannedTotal > filtered.length * 5 && filtered.isNotEmpty) {
      warnings.add(
        'Filters dropped ${scannedTotal - filtered.length} of $scannedTotal scanned requests, consider widening.',
      );
    }
    if (skippedErrors > 0) {
      warnings.add(
        'Skipped $skippedErrors request(s) that could not be read (likely '
        'in-flight/errored); the rest are returned.',
      );
    }
    if (budgetDropped > 0) {
      warnings.add(
        'Trimmed $budgetDropped request(s) to fit the $budget-token budget; '
        'page with since:<nextCursor> or raise maxTokens for the rest.',
      );
    }

    final nextSteps = <String>[];
    if (filtered.isNotEmpty) {
      nextSteps.add(
        'network_get id:"${filtered.first['id']}" — full headers + body for the top match',
      );
      if (caps.isEnabled(Category.search)) {
        nextSteps.add('network_search query:"..." — find requests by body/url content');
      }
      if (caps.isEnabled(Category.alerts)) {
        nextSteps.add('alerts_drain — surface anything the detector flagged');
      }
    } else {
      if (cursor != null) {
        nextSteps.add(
          'network_list since:0 to re-scan everything captured this session '
          '(this read was incremental and only shows new requests)',
        );
      }
      nextSteps.add('Drive the app to generate traffic, then call network_list again');
      if (activeFilters.isNotEmpty) {
        nextSteps.add('Drop filters to widen the match');
      }
    }

    return jsonResult({
      'source': 'live',
      'scope': scope.toBlock(),
      'sessionId': liveSid,
      'summary': summary,
      'count': filtered.length,
      'totalScanned': scannedTotal,
      if (skippedErrors > 0) 'partial': true,
      if (budget != null && budget > 0)
        'budget': {'maxTokens': budget, 'dropped': budgetDropped},
      if (latestCursor != null)
        'nextCursor': latestCursor.microsecondsSinceEpoch,
      if (warnings.isNotEmpty) 'warnings': warnings,
      'nextSteps': nextSteps,
      'requests': filtered,
    }, scopeSessionId: scope.sessionId, scopeNote: scope.note);
  } catch (e) {
    return _liveDbFallback(
      scope,
      caps,
      sinceArg,
      methods,
      hostContains,
      statusMin,
      statusMax,
      isolateFilter,
      limit,
      e,
    );
  }
}

/// Live read threw wholesale (the VM service rejected the profile fetch).
/// Return the DB-persisted snapshot for this session, flagged
/// `source: "live-db-fallback"`, so a blocked live path never reads as
/// "nothing captured / tool broken" when the DB still has every completed
/// request. (#41)
CallToolResult _liveDbFallback(
  Scope scope,
  CapabilityConfig caps,
  int? sinceArg,
  List<String>? methods,
  String? hostContains,
  int? statusMin,
  int? statusMax,
  String? isolateFilter,
  int limit,
  Object liveError,
) {
  final sid = scope.sessionId;
  List<Map<String, Object?>> rows;
  try {
    rows = CapturesDao().queryHttpRequests(
      sessionId: sid,
      sinceUs: (sinceArg != null && sinceArg > 0) ? sinceArg : null,
      methods: methods,
      hostContains: hostContains,
      statusMin: statusMin,
      statusMax: statusMax,
      isolateId: isolateFilter,
      limit: limit,
    );
  } catch (dbErr) {
    return errorResult(
      'Live read failed and the DB fallback also failed. '
      'Live: $liveError. DB: $dbErr',
      kind: ErrorKind.unresponsiveVm,
      extra: {
        'sessionId': sid,
        'nextSteps': const [
          'network_search query:"..." — DB-backed full-text search (works when the live path is down)',
          'network_query sql:"SELECT * FROM http_requests WHERE session_id=? ORDER BY start_us DESC" — raw SELECT over captures.db',
          'network_status — check VM service connection and zombie state',
        ],
      },
    );
  }

  int? minStart;
  final out = <Map<String, Object?>>[];
  for (final r in rows) {
    final start = r['start_us'] as int?;
    if (start != null && (minStart == null || start < minStart)) minStart = start;
    out.add(_historySummary(r));
  }
  final mayHaveOlder = rows.length >= limit && minStart != null;

  final nextSteps = <String>[
    if (out.isNotEmpty)
      'network_get id:"${out.first['id']}" — full detail for the top match',
    if (mayHaveOlder)
      'network_list before:$minStart — page OLDER than this batch',
    if (caps.isEnabled(Category.search))
      'network_search query:"..." — DB-backed full-text search (works when the live path is down)',
    'network_query sql:"SELECT * FROM http_requests WHERE session_id=$sid ORDER BY start_us DESC" — raw SELECT over captures.db',
    'network_status — check the live VM service connection',
  ];

  return jsonResult({
    'source': 'live-db-fallback',
    'scope': scope.toBlock(),
    'sessionId': sid,
    'summary': out.isEmpty
        ? 'Live read failed; no DB-persisted requests for session $sid yet.'
        : 'Live read failed; returning ${out.length} request(s) from the DB '
            'snapshot instead.',
    'count': out.length,
    // D4: newest-first snapshot — the productive page is OLDER.
    if (mayHaveOlder) 'nextCursor': minStart,
    'warnings': [
      'Live profile fetch failed: $liveError',
      'These rows are the persisted DB snapshot, not a live read. A single '
          'unresolvable/hung in-flight request can block the live path while '
          'completed requests stay captured here.',
    ],
    'nextSteps': nextSteps,
    'requests': out,
  }, scopeSessionId: sid);
}

FutureOr<CallToolResult> _historyList(
  Scope scope,
  CapabilityConfig caps,
  int? sinceArg,
  int? beforeArg,
  List<String>? methods,
  String? hostContains,
  int? statusMin,
  int? statusMax,
  String? isolateFilter,
  int limit,
  int? maxTokens,
) {
  final sid = scope.sessionId;
  try {
    final rows = CapturesDao().queryHttpRequests(
      sessionId: sid,
      sinceUs: sinceArg,
      beforeUs: beforeArg,
      methods: methods,
      hostContains: hostContains,
      statusMin: statusMin,
      statusMax: statusMax,
      isolateId: isolateFilter,
      limit: limit,
    );
    int? maxStart;
    int? minStart;
    final out = <Map<String, Object?>>[];
    for (final r in rows) {
      final start = r['start_us'] as int?;
      if (start != null && (maxStart == null || start > maxStart)) maxStart = start;
      if (start != null && (minStart == null || start < minStart)) minStart = start;
      out.add(_historySummary(r));
    }
    // A full page means older rows likely exist below the window.
    final mayHaveOlder = rows.length >= limit && minStart != null;

    final budgetTrim = trimToTokenBudget(out, maxTokens);
    final budgetDropped = budgetTrim.dropped;
    if (budgetDropped > 0) out.removeRange(budgetTrim.kept.length, out.length);

    final activeFilters =
        _activeFilters(methods, hostContains, statusMin, statusMax);
    final summary = out.isEmpty
        ? 'No requests in session $sid match the given filters/cursor.'
        : '${out.length} request(s) from session $sid (history, newest-first).';

    final warnings = <String>[];
    if (out.isEmpty && activeFilters.isNotEmpty) {
      warnings.add(
        'Filters may be too narrow — relax them or use network_search for content matching.',
      );
    }
    if (budgetDropped > 0) {
      warnings.add(
        'Trimmed $budgetDropped request(s) to fit the $maxTokens-token budget; '
        'raise maxTokens, or page OLDER with before:$minStart.',
      );
    }

    final nextSteps = <String>[];
    if (out.isNotEmpty) {
      nextSteps.add(
        'network_get id:"${out.first['id']}" — full headers + body for the top match',
      );
      if (caps.isEnabled(Category.search)) {
        nextSteps.add('network_search sessionId:$sid query:"..." — full-text search this session');
      }
      // D4 (RC7/F6): history is newest-first, so the useful page is OLDER.
      // The old hint ("since:<newest> — page beyond the newest") was a
      // guaranteed-empty dead end.
      if (mayHaveOlder) {
        nextSteps.add(
            'network_list before:$minStart — page OLDER than this batch');
      }
      if (maxStart != null && (beforeArg != null || sinceArg != null)) {
        nextSteps.add(
            'network_list since:$maxStart — page NEWER than this batch');
      }
    } else {
      // Cursor-aware empty hints: blaming filters when a cursor bound
      // excluded everything misdiagnoses the situation.
      if (beforeArg != null) {
        nextSteps.add(
            'Nothing older than before:$beforeArg — drop `before` to return to the newest page');
      } else if (sinceArg != null && sinceArg > 0) {
        nextSteps.add(
            'Nothing newer than since:$sinceArg — this session is history; new rows will not appear');
      } else {
        nextSteps.add('Widen filters (drop hostContains / lower statusMin)');
      }
      nextSteps.add('session_close — return to live (currently viewing session $sid)');
    }

    return jsonResult({
      'source': 'history',
      'scope': scope.toBlock(),
      'sessionId': sid,
      'summary': summary,
      'count': out.length,
      // D4: in history the productive direction is older; nextCursor feeds
      // `before:` (newestInBatch retained for since-paging).
      'nextCursor': mayHaveOlder ? minStart : null,
      if (maxStart != null) 'newestInBatch': maxStart,
      if (maxTokens != null && maxTokens > 0)
        'budget': {'maxTokens': maxTokens, 'dropped': budgetDropped},
      if (warnings.isNotEmpty) 'warnings': warnings,
      'nextSteps': nextSteps,
      'requests': out,
    }, scopeSessionId: scope.sessionId, scopeNote: scope.note);
  } catch (e) {
    return errorResult('history query failed: $e',
        kind: ErrorKind.internal,
        extra: {
          'sessionId': sid,
          'nextSteps': const [
            'Verify the session still exists via session_list',
            'session_close if the viewed session was deleted',
          ],
        });
  }
}

/// Builds one live-read summary row. Visible for testing.
///
/// Error-safe by construction (#41): a request in an error state must yield a
/// row, never throw.
Map<String, Object?> liveSummary(HttpProfileRequest r) {
  final reqErr = r.request?.hasError ?? false;
  final respErr = r.response?.hasError ?? false;
  final ct = firstHeader(r.response?.headers, 'content-type');
  // RC1: exchange end, not request-upload end — see util/http_timing.dart.
  final end = exchangeEndTime(r);
  return {
    'id': r.id,
    'method': r.method,
    'uri': r.uri.toString(),
    'host': r.uri.host,
    'path': r.uri.path,
    'startTimeMs': r.startTime.millisecondsSinceEpoch,
    if (end != null) 'endTimeMs': end.millisecondsSinceEpoch,
    if (end != null)
      'durationMs': end.difference(r.startTime).inMilliseconds,
    'isComplete': r.isRequestComplete,
    if (r.response?.statusCode != null) 'statusCode': r.response!.statusCode,
    if (r.response?.reasonPhrase != null) 'reasonPhrase': r.response!.reasonPhrase,
    if (!reqErr)
      ...sizeFields(r.request?.contentLength,
          key: 'requestContentLength', unknownKey: 'requestSizeKnown'),
    ...sizeFields(r.response?.contentLength,
        key: 'responseContentLength', unknownKey: 'responseSizeKnown'),
    if (ct != null) 'responseContentType': ct,
    if (reqErr || respErr) 'hasError': true,
    if (reqErr || respErr) 'error': r.request?.error ?? r.response?.error,
  };
}

Map<String, Object?> _historySummary(Map<String, Object?> r) {
  final start = r['start_us'] as int?;
  final end = r['end_us'] as int?;
  final dur = r['duration_us'] as int?;
  return {
    'id': r['vm_id'],
    'method': r['method'],
    'uri': r['url'],
    'host': r['host'],
    'path': r['path'],
    if (start != null) 'startTimeMs': start ~/ 1000,
    if (end != null) 'endTimeMs': end ~/ 1000,
    if (dur != null) 'durationMs': dur ~/ 1000,
    if (r['status_code'] != null) 'statusCode': r['status_code'],
    if (r['reason_phrase'] != null) 'reasonPhrase': r['reason_phrase'],
    ...sizeFields(r['request_size'] as int?,
        key: 'requestContentLength', unknownKey: 'requestSizeKnown'),
    ...sizeFields(r['response_size'] as int?,
        key: 'responseContentLength', unknownKey: 'responseSizeKnown'),
    if (r['content_type'] != null) 'responseContentType': r['content_type'],
    if (r['isolate_id'] != null) 'isolateId': r['isolate_id'],
    if ((r['has_error'] as int? ?? 0) != 0) 'hasError': true,
  };
}

List<String> _activeFilters(
  List<String>? methods,
  String? hostContains,
  int? min,
  int? max,
) {
  final filters = <String>[];
  if (methods != null && methods.isNotEmpty) {
    filters.add('method in [${methods.join(",")}]');
  }
  if (hostContains != null && hostContains.isNotEmpty) {
    filters.add('host~"$hostContains"');
  }
  if (min != null) filters.add('status>=$min');
  if (max != null) filters.add('status<=$max');
  return filters;
}

/// Summary line for a LIVE network_list read. Visible for testing.
///
/// The live read is cursor-based: each call advances the cursor, so a later
/// call sees only NEW requests. The key UX trap (found in live testing) is
/// the empty case: an incremental call that returns 0 must NOT read as "no
/// traffic" when the session already holds requests. The wording below makes
/// "0 new" distinct from "0 ever", and points an empty incremental read at
/// `since:0`.
///
/// - [matched]: rows returned after filtering.
/// - [scannedTotal]: rows the live profile returned before filtering.
/// - [cursorAdvanced]: a `since` cursor was in effect (`since` arg or stored).
/// - [incremental]: the cursor was the auto-advancing one (no explicit `since`).
String liveListSummary({
  required int matched,
  required int scannedTotal,
  required bool cursorAdvanced,
  required bool incremental,
  required String scopeLabel,
}) {
  if (matched > 0) {
    return '$matched request(s) from $scopeLabel, newest-first'
        '${incremental ? " (new since your last call)" : ""}.';
  }
  if (scannedTotal > 0) {
    return '$scannedTotal request(s) scanned, 0 matched filters.';
  }
  if (!cursorAdvanced) {
    return 'No HTTP captured yet in $scopeLabel.';
  }
  return incremental
      ? 'No NEW HTTP since your last call to $scopeLabel. This read is '
          'incremental; pass since:0 to re-scan everything captured, or use '
          'network_summarize for the session shape.'
      : 'No HTTP newer than your since cursor in $scopeLabel; pass since:0 '
          'to re-scan everything captured.';
}
