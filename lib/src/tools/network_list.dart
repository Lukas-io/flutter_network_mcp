import 'dart:async';

import 'package:dart_mcp/server.dart';
import 'package:vm_service/vm_service.dart';

import '../config/capabilities.dart';
import '../config/session_filters.dart';
import '../state/session.dart';
import '../storage/captures_db.dart';
import '../util/body_decoder.dart';
import '../util/filters.dart';
import '../util/scope.dart';
import 'result.dart';

final networkListTool = Tool(
  name: 'network_list',
  description:
      'Lists captured HTTP requests, newest-first. Returns summaries only — '
      'never bodies. The default `since` cursor is incremental: subsequent '
      'calls return only what is new. Pass `since:0` to fetch everything; '
      'pass `nextCursor` from a prior call to continue paging. When a session '
      'is opened via session_open, reads from history instead of live VM.',
  inputSchema: Schema.object(
    properties: {
      'sessionId': Schema.int(
        description:
            'Which session to read from. Omit to auto-resolve: explicit '
            'view (session_open) → sole attached session → error if 2+ '
            'attached.',
      ),
      'appNameContains': Schema.string(
        description:
            'Alternative to sessionId — case-insensitive substring match '
            'against currently-attached app names. Must match exactly one.',
      ),
      'since': Schema.int(
        description:
            'Microsecond cursor — epoch micros (live mode) or start_us '
            'threshold (history mode). Omit to use the live session\'s stored '
            'cursor (incremental). Pass 0 to fetch everything captured. '
            'Typical usage: pass the `nextCursor` value from your prior call.',
      ),
      'method': Schema.list(
        description: 'Filter by HTTP method(s), e.g. ["GET","POST"]. Omit for all methods.',
        items: Schema.string(),
      ),
      'hostContains': Schema.string(
        description: 'Substring match (case-insensitive) on the request host.',
      ),
      'statusMin': Schema.int(
        description: 'Inclusive lower bound on response status code (e.g. 400 for errors).',
      ),
      'statusMax': Schema.int(
        description: 'Inclusive upper bound on response status code.',
      ),
      'isolateId': Schema.string(
        description:
            'Optional: restrict to one isolate within the session (e.g. a '
            'worker isolate). Get the id from network_status.attached[].'
            'isolates[]. Omit to merge every isolate in the session (the '
            'default — same UX as single-isolate apps).',
      ),
      'limit': Schema.int(
        description: 'Max requests returned (default 50, hard cap 200). Newest-first.',
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

  // Sticky defaults (#18): inherit from session_configure when an arg is
  // omitted; an explicitly-passed arg (even null) wins for this call.
  final sf = SessionFilters.instance;
  final sinceArg = args['since'] as int?;
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

  // History mode: scope is non-live (explicit sessionId arg pointing at a
  // historical session, or session_open's viewedSessionId resolves to one
  // that isn't currently attached).
  if (!scope.isLive) {
    return _historyList(
      scope,
      caps,
      sinceArg,
      methods,
      hostContains,
      statusMin,
      statusMax,
      isolateFilter,
      limit,
    );
  }

  // Live mode — scope points at an attached session; look up its resources.
  final attached = SessionRegistry.instance.attachedById(scope.sessionId)!;
  final cursor = sinceArg == null
      ? attached.lastHttpCursor
      : (sinceArg <= 0 ? null : DateTime.fromMicrosecondsSinceEpoch(sinceArg));

  // Multi-isolate live read: iterate every HTTP-profiling isolate (or the
  // one named by [isolateFilter]) and merge. Each isolate has its own VM-
  // side profile; the per-isolate try/catch keeps a flaky isolate from
  // breaking the others.
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

    // Sort by start time across all isolates (newest first).
    perIsolateRequests
        .sort((a, b) => b.$1.startTime.compareTo(a.$1.startTime));

    final filtered = <Map<String, Object?>>[];
    for (final (req, isoId) in perIsolateRequests) {
      if (!methodMatches(req.method, methods)) continue;
      if (!hostMatches(req.uri.toString(), hostContains)) continue;
      if (!statusInRange(req.response?.statusCode, statusMin, statusMax)) {
        continue;
      }
      final summary = _liveSummary(req);
      summary['isolateId'] = isoId;
      filtered.add(summary);
      if (filtered.length >= limit) break;
    }

    final liveSid = scope.sessionId;
    final activeFilters =
        _activeFilters(methods, hostContains, statusMin, statusMax);
    final cursorWasIncremental = sinceArg == null && cursor != null;

    final summary = filtered.isEmpty
        ? (scannedTotal == 0
            ? 'No HTTP captured yet in session $liveSid (live${scope.appName != null ? ", ${scope.appName}" : ""}).'
            : '$scannedTotal request(s) scanned, 0 matched filters.')
        : '${filtered.length} request(s) from session $liveSid (live${scope.appName != null ? ", ${scope.appName}" : ""}, newest-first)'
            '${cursorWasIncremental ? " — incremental since last call" : ""}.';

    final warnings = <String>[];
    if (filtered.isEmpty && scannedTotal == 0 && cursor == null) {
      warnings.add(
        'Capture profile is empty — drive the app to generate traffic, then re-call.',
      );
    } else if (filtered.isEmpty && scannedTotal == 0 && cursor != null) {
      warnings.add(
        'No new captures since the last cursor. Drive the app or pass since:0 to re-scan everything.',
      );
    } else if (filtered.isEmpty && scannedTotal > 0) {
      warnings.add(
        'Filters excluded all $scannedTotal captured request(s).',
      );
    }
    if (scannedTotal > filtered.length * 5 && filtered.isNotEmpty) {
      warnings.add(
        'Filters dropped ${scannedTotal - filtered.length} of $scannedTotal scanned requests — consider widening.',
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
      nextSteps.add(
        'Drive the app to generate traffic, then call network_list again (cursor is incremental)',
      );
      if (activeFilters.isNotEmpty) {
        nextSteps.add('Drop filters and pass since:0 to re-scan from the start');
      }
    }

    return jsonResult({
      'source': 'live',
      'scope': scope.toBlock(),
      'sessionId': liveSid,
      'summary': summary,
      'count': filtered.length,
      'totalScanned': scannedTotal,
      if (latestCursor != null)
        'nextCursor': latestCursor.microsecondsSinceEpoch,
      if (warnings.isNotEmpty) 'warnings': warnings,
      'nextSteps': nextSteps,
      'requests': filtered,
    }, scopeSessionId: scope.sessionId);
  } catch (e) {
    return errorResult('getHttpProfile failed: $e', extra: const {
      'nextSteps': [
        'network_status — check VM service connection and zombie state',
        'network_detach then network_attach — full reset',
      ],
    });
  }
}

FutureOr<CallToolResult> _historyList(
  Scope scope,
  CapabilityConfig caps,
  int? sinceArg,
  List<String>? methods,
  String? hostContains,
  int? statusMin,
  int? statusMax,
  String? isolateFilter,
  int limit,
) {
  final sid = scope.sessionId;
  try {
    final rows = CapturesDao().queryHttpRequests(
      sessionId: sid,
      sinceUs: sinceArg,
      methods: methods,
      hostContains: hostContains,
      statusMin: statusMin,
      statusMax: statusMax,
      isolateId: isolateFilter,
      limit: limit,
    );
    int? maxStart;
    final out = <Map<String, Object?>>[];
    for (final r in rows) {
      final start = r['start_us'] as int?;
      if (start != null && (maxStart == null || start > maxStart)) maxStart = start;
      out.add(_historySummary(r));
    }

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

    final nextSteps = <String>[];
    if (out.isNotEmpty) {
      nextSteps.add(
        'network_get id:"${out.first['id']}" — full headers + body for the top match',
      );
      if (caps.isEnabled(Category.search)) {
        nextSteps.add('network_search sessionId:$sid query:"..." — full-text search this session');
      }
      if (maxStart != null) {
        nextSteps.add('network_list since:$maxStart — page beyond the newest in this batch');
      }
    } else {
      nextSteps.add('Widen filters (drop hostContains / lower statusMin)');
      nextSteps.add('session_close — return to live (currently viewing session $sid)');
    }

    return jsonResult({
      'source': 'history',
      'scope': scope.toBlock(),
      'sessionId': sid,
      'summary': summary,
      'count': out.length,
      'nextCursor': maxStart,
      if (warnings.isNotEmpty) 'warnings': warnings,
      'nextSteps': nextSteps,
      'requests': out,
    }, scopeSessionId: scope.sessionId);
  } catch (e) {
    return errorResult('history query failed: $e', extra: {
      'sessionId': sid,
      'nextSteps': const [
        'Verify the session still exists via session_list',
        'session_close if the viewed session was deleted',
      ],
    });
  }
}

Map<String, Object?> _liveSummary(HttpProfileRequest r) {
  final ct = firstHeader(r.response?.headers, 'content-type');
  return {
    'id': r.id,
    'method': r.method,
    'uri': r.uri.toString(),
    'host': r.uri.host,
    'path': r.uri.path,
    'startTimeMs': r.startTime.millisecondsSinceEpoch,
    if (r.endTime != null) 'endTimeMs': r.endTime!.millisecondsSinceEpoch,
    if (r.endTime != null)
      'durationMs': r.endTime!.difference(r.startTime).inMilliseconds,
    'isComplete': r.isRequestComplete,
    if (r.response?.statusCode != null) 'statusCode': r.response!.statusCode,
    if (r.response?.reasonPhrase != null) 'reasonPhrase': r.response!.reasonPhrase,
    if (r.request?.contentLength != null) 'requestContentLength': r.request!.contentLength,
    if (r.response?.contentLength != null) 'responseContentLength': r.response!.contentLength,
    if (ct != null) 'responseContentType': ct,
    if ((r.request?.hasError ?? false) || (r.response?.hasError ?? false)) 'hasError': true,
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
    if (r['request_size'] != null) 'requestContentLength': r['request_size'],
    if (r['response_size'] != null) 'responseContentLength': r['response_size'],
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
