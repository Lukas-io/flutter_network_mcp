import 'dart:async';
import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:vm_service/vm_service.dart';

import '../config/capabilities.dart';
import '../state/session.dart';
import '../storage/captures_db.dart';
import '../util/body_decoder.dart';
import 'result.dart';

final networkGetTool = Tool(
  name: 'network_get',
  description:
      'Returns full details for ONE captured HTTP request: headers, timing, '
      'and (optionally) decoded request/response bodies. Bodies truncate to '
      '`bodyTruncateBytes` (default 4 KB) — truncation is signaled both in '
      'each body sub-object and in a top-level `warnings` array. Lifecycle '
      'events are opt-in to keep payloads small.',
  inputSchema: Schema.object(
    properties: {
      'id': Schema.string(
        description:
            'Request id from a prior network_list / network_search call.',
      ),
      'includeBodies': Schema.bool(
        description: 'Omit request + response bodies entirely. Default true.',
      ),
      'bodyTruncateBytes': Schema.int(
        description:
            'Max bytes per body before truncation (default 4096, hard cap '
            '262144 — pass 0 to use the hard cap). Truncated bodies include '
            '{truncated:true,totalSize:N}; agents should follow with '
            'network_body for byte-range fetches.',
      ),
      'headerTruncateBytes': Schema.int(
        description:
            'Max chars per header VALUE before each long value becomes a '
            '{value,truncated,totalLength} object (default 256, max 4096).',
      ),
      'includeEvents': Schema.bool(
        description:
            'Include the request lifecycle events array (HttpProfileRequest.events). '
            'Default false — events are rarely useful and add bulk.',
      ),
    },
    required: ['id'],
  ),
);

const _kBodyHardCap = 262144;
const _kHeaderHardCap = 4096;
const _kMaxEvents = 50;

FutureOr<CallToolResult> networkGet(CallToolRequest request) async {
  final session = Session.instance;
  final caps = CapabilityConfig.instance;
  final args = request.arguments ?? const <String, Object?>{};
  final id = args['id'] as String?;
  if (id == null || id.isEmpty) {
    return errorResult('Missing required arg `id`.', extra: const {
      'nextSteps': [
        'network_list — list captured requests and copy an id',
        'network_search query:"..." — find a request by body/url content',
      ],
    });
  }
  final includeBodies = (args['includeBodies'] as bool?) ?? true;
  final includeEvents = (args['includeEvents'] as bool?) ?? false;
  final truncateRaw = args['bodyTruncateBytes'] as int?;
  final maxBytes = (truncateRaw == null)
      ? 4096
      : (truncateRaw <= 0 ? _kBodyHardCap : (truncateRaw > _kBodyHardCap ? _kBodyHardCap : truncateRaw));
  final headerTruncateRaw = args['headerTruncateBytes'] as int?;
  final headerTruncateBytes = (headerTruncateRaw == null || headerTruncateRaw <= 0)
      ? 256
      : (headerTruncateRaw > _kHeaderHardCap ? _kHeaderHardCap : headerTruncateRaw);

  if (session.isViewingHistory) {
    return _historyGet(
      sid: session.viewedSessionId!,
      id: id,
      includeBodies: includeBodies,
      includeEvents: includeEvents,
      maxBytes: maxBytes,
      headerTruncateBytes: headerTruncateBytes,
      caps: caps,
    );
  }

  if (!session.isAttached) {
    return errorResult(
      'Not attached and no session opened — cannot fetch a request.',
      extra: const {
        'nextSteps': [
          'network_status — see DTD apps',
          'network_attach — connect to a live app',
          'session_open id:<n> — view a past session and try this id there',
        ],
      },
    );
  }

  try {
    final r = await session.vm.getHttpProfileRequest(id);
    return _buildLiveResponse(
      r: r,
      sessionId: session.liveSessionId,
      includeBodies: includeBodies,
      includeEvents: includeEvents,
      maxBytes: maxBytes,
      headerTruncateBytes: headerTruncateBytes,
      caps: caps,
    );
  } catch (e) {
    return errorResult('getHttpProfileRequest failed: $e', extra: {
      'id': id,
      'nextSteps': const [
        'Verify the id exists via network_list',
        'network_status — check VM service / zombie-DTD state',
      ],
    });
  }
}

CallToolResult _buildLiveResponse({
  required HttpProfileRequest r,
  required int? sessionId,
  required bool includeBodies,
  required bool includeEvents,
  required int maxBytes,
  required int headerTruncateBytes,
  required CapabilityConfig caps,
}) {
  final reqCt = firstHeader(r.request?.headers, 'content-type');
  final respCt = firstHeader(r.response?.headers, 'content-type');
  final reqBody = includeBodies
      ? decodeBody(r.requestBody, reqCt, maxBytes: maxBytes)?.toJson()
      : null;
  final respBody = includeBodies
      ? decodeBody(r.responseBody, respCt, maxBytes: maxBytes)?.toJson()
      : null;

  final requestData = r.request == null
      ? null
      : {
          if (r.request!.hasError) 'error': r.request!.error,
          if (!r.request!.hasError) ...{
            'headers': truncateHeaders(r.request!.headers, maxValueBytes: headerTruncateBytes),
            if (r.request!.contentLength != null) 'contentLength': r.request!.contentLength,
            if ((r.request!.cookies ?? []).isNotEmpty) 'cookies': r.request!.cookies,
          },
          if (reqBody != null) 'body': reqBody,
        };
  final responseData = r.response == null
      ? null
      : {
          if (r.response!.hasError) 'error': r.response!.error,
          if (!r.response!.hasError) ...{
            if (r.response!.statusCode != null) 'statusCode': r.response!.statusCode,
            if (r.response!.reasonPhrase != null) 'reasonPhrase': r.response!.reasonPhrase,
            'headers': truncateHeaders(r.response!.headers, maxValueBytes: headerTruncateBytes),
            if (r.response!.contentLength != null) 'contentLength': r.response!.contentLength,
            if (r.response!.compressionState != null) 'compressionState': r.response!.compressionState,
          },
          if (respBody != null) 'body': respBody,
        };

  final warnings = _warningsFor(
    requestBody: reqBody,
    responseBody: respBody,
    isRequestComplete: r.isRequestComplete,
    isResponseComplete: r.isResponseComplete,
    requestError: r.request?.hasError == true ? r.request!.error : null,
    responseError: r.response?.hasError == true ? r.response!.error : null,
  );

  final reqDurationMs = r.endTime?.difference(r.startTime).inMilliseconds;
  final summary = _summaryFor(
    method: r.method,
    uri: r.uri.toString(),
    statusCode: r.response?.statusCode,
    reasonPhrase: r.response?.reasonPhrase,
    durationMs: reqDurationMs,
    responseSize: r.response?.contentLength,
    responseContentType: respCt,
    inFlight: !r.isResponseComplete,
    hasError: warnings.any((w) => w.contains('error')),
  );

  return jsonResult({
    'source': 'live',
    'sessionId': sessionId,
    'summary': summary,
    'id': r.id,
    'method': r.method,
    'uri': r.uri.toString(),
    'startTimeMs': r.startTime.millisecondsSinceEpoch,
    if (r.endTime != null) 'endTimeMs': r.endTime!.millisecondsSinceEpoch,
    if (reqDurationMs != null) 'durationMs': reqDurationMs,
    'isComplete': r.isRequestComplete,
    'isResponseComplete': r.isResponseComplete,
    if (includeEvents) 'events': _truncateEvents(r.events),
    'request': requestData,
    'response': responseData,
    if (warnings.isNotEmpty) 'warnings': warnings,
    'nextSteps': _nextStepsFor(
      caps: caps,
      id: r.id,
      requestBody: reqBody,
      responseBody: respBody,
    ),
  });
}

FutureOr<CallToolResult> _historyGet({
  required int sid,
  required String id,
  required bool includeBodies,
  required bool includeEvents,
  required int maxBytes,
  required int headerTruncateBytes,
  required CapabilityConfig caps,
}) {
  try {
    final dao = CapturesDao();
    final row = dao.getHttpRequest(sid, id);
    if (row == null) {
      return errorResult('Request `$id` not found in session $sid.', extra: {
        'sessionId': sid,
        'nextSteps': const [
          'network_list — list valid request ids in this session',
          'session_list — confirm the session id is correct',
        ],
      });
    }
    final reqHeaders = _parseHeaders(row['request_headers_json']);
    final respHeaders = _parseHeaders(row['response_headers_json']);
    final reqCt = row['content_type'] as String? ?? firstHeader(reqHeaders, 'content-type');
    final respCt = row['content_type'] as String? ?? firstHeader(respHeaders, 'content-type');
    final reqBlob = includeBodies ? dao.getBody(sid, id, 'request') : null;
    final respBlob = includeBodies ? dao.getBody(sid, id, 'response') : null;
    final reqBody = reqBlob == null ? null : decodeBody(reqBlob, reqCt, maxBytes: maxBytes)?.toJson();
    final respBody = respBlob == null ? null : decodeBody(respBlob, respCt, maxBytes: maxBytes)?.toJson();

    final startUs = row['start_us'] as int?;
    final endUs = row['end_us'] as int?;
    final durUs = row['duration_us'] as int?;
    final hasError = (row['has_error'] as int? ?? 0) != 0;

    final requestData = {
      if (reqHeaders != null)
        'headers': truncateHeaders(reqHeaders, maxValueBytes: headerTruncateBytes),
      if (row['request_size'] != null) 'contentLength': row['request_size'],
      if (reqBody != null) 'body': reqBody,
    };
    final responseData = {
      if (row['status_code'] != null) 'statusCode': row['status_code'],
      if (row['reason_phrase'] != null) 'reasonPhrase': row['reason_phrase'],
      if (respHeaders != null)
        'headers': truncateHeaders(respHeaders, maxValueBytes: headerTruncateBytes),
      if (row['response_size'] != null) 'contentLength': row['response_size'],
      if (respBody != null) 'body': respBody,
    };

    final warnings = _warningsFor(
      requestBody: reqBody,
      responseBody: respBody,
      isRequestComplete: endUs != null,
      isResponseComplete: endUs != null,
      requestError: hasError ? '(see has_error flag)' : null,
      responseError: null,
    );
    if (reqBlob == null && includeBodies) {
      warnings.add('Request body not persisted yet (writer may still be backfilling).');
    }
    if (respBlob == null && includeBodies && row['response_size'] != null) {
      warnings.add('Response body not persisted yet (writer may still be backfilling).');
    }

    final durMs = durUs == null ? null : durUs ~/ 1000;
    final summary = _summaryFor(
      method: row['method'] as String? ?? '?',
      uri: row['url'] as String? ?? '',
      statusCode: row['status_code'] as int?,
      reasonPhrase: row['reason_phrase'] as String?,
      durationMs: durMs,
      responseSize: row['response_size'] as int?,
      responseContentType: respCt,
      inFlight: endUs == null,
      hasError: hasError,
    );

    return jsonResult({
      'source': 'history',
      'sessionId': sid,
      'summary': summary,
      'id': id,
      'method': row['method'],
      'uri': row['url'],
      if (startUs != null) 'startTimeMs': startUs ~/ 1000,
      if (endUs != null) 'endTimeMs': endUs ~/ 1000,
      if (durMs != null) 'durationMs': durMs,
      'request': requestData,
      'response': responseData,
      if (warnings.isNotEmpty) 'warnings': warnings,
      'nextSteps': _nextStepsFor(
        caps: caps,
        id: id,
        requestBody: reqBody,
        responseBody: respBody,
      ),
    });
  } catch (e) {
    return errorResult('history query failed: $e', extra: {
      'sessionId': sid,
      'id': id,
      'nextSteps': const [
        'Verify the session still exists via session_list',
        'session_close to return to live mode',
      ],
    });
  }
}

List<String> _warningsFor({
  required Map<String, Object?>? requestBody,
  required Map<String, Object?>? responseBody,
  required bool isRequestComplete,
  required bool isResponseComplete,
  String? requestError,
  String? responseError,
}) {
  final w = <String>[];
  if (requestBody?['truncated'] == true) {
    final total = requestBody!['totalSize'];
    w.add('Request body truncated — totalSize $total bytes. Call network_body which:request for the full payload.');
  }
  if (responseBody?['truncated'] == true) {
    final total = responseBody!['totalSize'];
    w.add('Response body truncated — totalSize $total bytes. Call network_body which:response for the full payload.');
  }
  if (!isRequestComplete) {
    w.add('Request is still in flight; response will be incomplete or absent.');
  } else if (!isResponseComplete) {
    w.add('Response not yet complete; bodies may grow on a subsequent call.');
  }
  if (requestError != null) w.add('Request error: $requestError');
  if (responseError != null) w.add('Response error: $responseError');
  return w;
}

List<String> _nextStepsFor({
  required CapabilityConfig caps,
  required String id,
  required Map<String, Object?>? requestBody,
  required Map<String, Object?>? responseBody,
}) {
  final steps = <String>[];
  final reqTrunc = requestBody?['truncated'] == true;
  final respTrunc = responseBody?['truncated'] == true;
  if (caps.isEnabled(Category.http)) {
    if (respTrunc) {
      final total = responseBody!['totalSize'];
      steps.add('network_body id:"$id" which:response offset:4096 length:16384 — page beyond the cap (totalSize $total)');
    } else if (reqTrunc) {
      final total = requestBody!['totalSize'];
      steps.add('network_body id:"$id" which:request offset:4096 length:16384 — page beyond the cap (totalSize $total)');
    }
    steps.add('network_replay id:"$id" — runnable curl reproduction (auth headers redacted)');
    steps.add('network_diff idA:"$id" idB:"<other id>" — compare with another captured request');
  }
  return steps;
}

String _summaryFor({
  required String method,
  required String uri,
  required int? statusCode,
  required String? reasonPhrase,
  required int? durationMs,
  required int? responseSize,
  required String? responseContentType,
  required bool inFlight,
  required bool hasError,
}) {
  final shortUri = uri.length > 60 ? '${uri.substring(0, 57)}...' : uri;
  final parts = <String>['$method $shortUri →'];
  if (hasError) {
    parts.add('error');
  } else if (inFlight) {
    parts.add('in flight');
  } else if (statusCode != null) {
    parts.add('$statusCode${reasonPhrase != null ? " $reasonPhrase" : ""}');
  } else {
    parts.add('(no response)');
  }
  if (durationMs != null) parts.add('· ${durationMs}ms');
  if (responseSize != null && responseSize > 0) parts.add('· $responseSize-byte response');
  if (responseContentType != null) {
    final ct = responseContentType.split(';').first;
    parts.add('($ct)');
  }
  return parts.join(' ');
}

List<Map<String, Object?>> _truncateEvents(List<HttpProfileRequestEvent> events) {
  if (events.length <= _kMaxEvents) {
    return [
      for (final e in events)
        {
          'event': e.event,
          'timestampMs': e.timestamp.millisecondsSinceEpoch,
          if (e.arguments != null) 'arguments': e.arguments,
        },
    ];
  }
  return [
    for (final e in events.take(_kMaxEvents))
      {
        'event': e.event,
        'timestampMs': e.timestamp.millisecondsSinceEpoch,
        if (e.arguments != null) 'arguments': e.arguments,
      },
    {'_omitted': events.length - _kMaxEvents},
  ];
}

Map<String, dynamic>? _parseHeaders(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  try {
    return jsonDecode(raw) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}
