import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../storage/captures_db.dart';
import '../util/body_decoder.dart';
import '../util/filters.dart';
import 'result.dart';

final networkListTool = Tool(
  name: 'network_list',
  description:
      'Lists captured HTTP requests, newest-first. Summary fields only — no '
      'bodies. When `viewedSessionId` is set via session_open, returns data '
      'from the persistent DB; otherwise reads live from the VM service.',
  inputSchema: Schema.object(
    properties: {
      'since': Schema.int(
        description:
            'Microsecond cursor from a prior nextCursor (live mode) OR a '
            'start_us threshold (history mode). Omit for default behavior.',
      ),
      'method': Schema.list(
        description: 'Filter by HTTP method(s), e.g. ["GET","POST"].',
        items: Schema.string(),
      ),
      'hostContains': Schema.string(description: 'Substring match (case-insensitive) on host.'),
      'statusMin': Schema.int(description: 'Inclusive lower bound on status code.'),
      'statusMax': Schema.int(description: 'Inclusive upper bound on status code.'),
      'limit': Schema.int(description: 'Max results (default 50, hard cap 200).'),
    },
  ),
);

FutureOr<CallToolResult> networkList(CallToolRequest request) async {
  final session = Session.instance;
  final args = request.arguments ?? const <String, Object?>{};
  final sinceArg = args['since'] as int?;
  final methods = readStringList(args['method']);
  final hostContains = args['hostContains'] as String?;
  final statusMin = args['statusMin'] as int?;
  final statusMax = args['statusMax'] as int?;
  final limit = clampLimit(args['limit'] as int?, fallback: 50, hardMax: 200);

  if (session.isViewingHistory) {
    final sid = session.viewedSessionId!;
    try {
      final rows = CapturesDao().queryHttpRequests(
        sessionId: sid,
        sinceUs: sinceArg,
        methods: methods,
        hostContains: hostContains,
        statusMin: statusMin,
        statusMax: statusMax,
        limit: limit,
      );
      int? maxStart;
      final out = <Map<String, Object?>>[];
      for (final r in rows) {
        final start = r['start_us'] as int?;
        if (start != null && (maxStart == null || start > maxStart)) maxStart = start;
        out.add({
          'id': r['vm_id'],
          'method': r['method'],
          'uri': r['url'],
          'host': r['host'],
          'path': r['path'],
          'startTimeMs': start == null ? null : (start ~/ 1000),
          'endTimeMs':
              (r['end_us'] as int?) == null ? null : ((r['end_us'] as int) ~/ 1000),
          'durationMs':
              (r['duration_us'] as int?) == null ? null : ((r['duration_us'] as int) ~/ 1000),
          'statusCode': r['status_code'],
          'reasonPhrase': r['reason_phrase'],
          'requestContentLength': r['request_size'],
          'responseContentLength': r['response_size'],
          'responseContentType': r['content_type'],
          'hasError': (r['has_error'] as int? ?? 0) != 0,
        });
      }
      return jsonResult({
        'source': 'history',
        'sessionId': sid,
        'count': out.length,
        'nextCursor': maxStart,
        'requests': out,
      });
    } catch (e) {
      return errorResult('history query failed: $e');
    }
  }

  // Live mode.
  if (!session.isAttached) {
    return errorResult('Not attached. Call network_attach first.');
  }

  final cursor = sinceArg == null
      ? session.lastHttpCursor
      : (sinceArg <= 0 ? null : DateTime.fromMicrosecondsSinceEpoch(sinceArg));

  try {
    final profile = await session.vm.getHttpProfile(updatedSince: cursor);
    session.lastHttpCursor = profile.timestamp;

    final filtered = <Map<String, Object?>>[];
    final sorted = profile.requests.toList()
      ..sort((a, b) => b.startTime.compareTo(a.startTime));

    for (final r in sorted) {
      if (!methodMatches(r.method, methods)) continue;
      if (!hostMatches(r.uri.toString(), hostContains)) continue;
      final code = r.response?.statusCode;
      if (!statusInRange(code, statusMin, statusMax)) continue;

      filtered.add({
        'id': r.id,
        'method': r.method,
        'uri': r.uri.toString(),
        'host': r.uri.host,
        'path': r.uri.path,
        'startTimeMs': r.startTime.millisecondsSinceEpoch,
        'endTimeMs': r.endTime?.millisecondsSinceEpoch,
        'durationMs': r.endTime?.difference(r.startTime).inMilliseconds,
        'isComplete': r.isRequestComplete,
        'statusCode': code,
        'reasonPhrase': r.response?.reasonPhrase,
        'requestContentLength': r.request?.contentLength,
        'responseContentLength': r.response?.contentLength,
        'responseContentType': firstHeader(r.response?.headers, 'content-type'),
        'hasError':
            (r.request?.hasError ?? false) || (r.response?.hasError ?? false),
      });
      if (filtered.length >= limit) break;
    }

    return jsonResult({
      'source': 'live',
      'sessionId': session.liveSessionId,
      'count': filtered.length,
      'totalScanned': profile.requests.length,
      'nextCursor': profile.timestamp.microsecondsSinceEpoch,
      'requests': filtered,
    });
  } catch (e) {
    return errorResult('getHttpProfile failed: $e');
  }
}
