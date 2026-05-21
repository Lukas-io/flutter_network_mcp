import 'dart:async';
import 'dart:convert';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../storage/captures_db.dart';
import '../util/body_decoder.dart';
import 'result.dart';

final networkGetTool = Tool(
  name: 'network_get',
  description:
      'Returns the full details of a single HTTP request: headers, timing, '
      'and (optionally) decoded request/response bodies. In live mode, reads '
      'from the VM service. In history mode (after session_open), reads from '
      'the persistent DB.',
  inputSchema: Schema.object(
    properties: {
      'id': Schema.string(description: 'Request id from network_list.'),
      'includeBodies': Schema.bool(description: 'When false, omit bodies. Default true.'),
      'bodyTruncateBytes': Schema.int(
        description: 'Max bytes per body. Pass 0 or negative for unlimited. Default 4096.',
      ),
    },
    required: ['id'],
  ),
);

FutureOr<CallToolResult> networkGet(CallToolRequest request) async {
  final session = Session.instance;
  final args = request.arguments ?? const <String, Object?>{};
  final id = args['id'] as String?;
  if (id == null || id.isEmpty) {
    return errorResult('Missing required arg `id`.');
  }
  final includeBodies = (args['includeBodies'] as bool?) ?? true;
  final truncateRaw = args['bodyTruncateBytes'] as int?;
  final maxBytes = (truncateRaw == null) ? 4096 : (truncateRaw <= 0 ? -1 : truncateRaw);

  if (session.isViewingHistory) {
    return _historyGet(session.viewedSessionId!, id, includeBodies, maxBytes);
  }

  if (!session.isAttached) {
    return errorResult('Not attached. Call network_attach first.');
  }

  try {
    final r = await session.vm.getHttpProfileRequest(id);
    final reqContentType = firstHeader(r.request?.headers, 'content-type');
    final respContentType = firstHeader(r.response?.headers, 'content-type');

    return jsonResult({
      'source': 'live',
      'sessionId': session.liveSessionId,
      'id': r.id,
      'method': r.method,
      'uri': r.uri.toString(),
      'startTimeMs': r.startTime.millisecondsSinceEpoch,
      'endTimeMs': r.endTime?.millisecondsSinceEpoch,
      'durationMs': r.endTime?.difference(r.startTime).inMilliseconds,
      'isComplete': r.isRequestComplete,
      'isResponseComplete': r.isResponseComplete,
      'events': [
        for (final e in r.events)
          {
            'event': e.event,
            'timestampMs': e.timestamp.millisecondsSinceEpoch,
            if (e.arguments != null) 'arguments': e.arguments,
          },
      ],
      'request': r.request == null
          ? null
          : {
              if (r.request!.hasError) 'error': r.request!.error,
              if (!r.request!.hasError) ...{
                'headers': r.request!.headers,
                'contentLength': r.request!.contentLength,
                'cookies': r.request!.cookies,
              },
              if (includeBodies)
                'body': decodeBody(r.requestBody, reqContentType, maxBytes: maxBytes)?.toJson(),
            },
      'response': r.response == null
          ? null
          : {
              if (r.response!.hasError) 'error': r.response!.error,
              if (!r.response!.hasError) ...{
                'statusCode': r.response!.statusCode,
                'reasonPhrase': r.response!.reasonPhrase,
                'headers': r.response!.headers,
                'contentLength': r.response!.contentLength,
                'compressionState': r.response!.compressionState,
              },
              if (includeBodies)
                'body': decodeBody(r.responseBody, respContentType, maxBytes: maxBytes)?.toJson(),
            },
    });
  } catch (e) {
    return errorResult('getHttpProfileRequest failed: $e');
  }
}

FutureOr<CallToolResult> _historyGet(int sid, String id, bool includeBodies, int maxBytes) {
  try {
    final dao = CapturesDao();
    final row = dao.getHttpRequest(sid, id);
    if (row == null) {
      return errorResult('Request `$id` not found in session $sid.');
    }
    final reqHeaders = _parseHeaders(row['request_headers_json']);
    final respHeaders = _parseHeaders(row['response_headers_json']);
    final reqCt = row['content_type'] as String? ?? firstHeader(reqHeaders, 'content-type');
    final respCt = row['content_type'] as String? ?? firstHeader(respHeaders, 'content-type');
    final reqBody = includeBodies ? dao.getBody(sid, id, 'request') : null;
    final respBody = includeBodies ? dao.getBody(sid, id, 'response') : null;

    return jsonResult({
      'source': 'history',
      'sessionId': sid,
      'id': id,
      'method': row['method'],
      'uri': row['url'],
      'startTimeMs': (row['start_us'] as int?) == null ? null : ((row['start_us'] as int) ~/ 1000),
      'endTimeMs': (row['end_us'] as int?) == null ? null : ((row['end_us'] as int) ~/ 1000),
      'durationMs':
          (row['duration_us'] as int?) == null ? null : ((row['duration_us'] as int) ~/ 1000),
      'request': {
        if (reqHeaders != null) 'headers': reqHeaders,
        'contentLength': row['request_size'],
        if (includeBodies && reqBody != null)
          'body': decodeBody(reqBody, reqCt, maxBytes: maxBytes)?.toJson(),
      },
      'response': {
        'statusCode': row['status_code'],
        'reasonPhrase': row['reason_phrase'],
        if (respHeaders != null) 'headers': respHeaders,
        'contentLength': row['response_size'],
        if (includeBodies && respBody != null)
          'body': decodeBody(respBody, respCt, maxBytes: maxBytes)?.toJson(),
      },
    });
  } catch (e) {
    return errorResult('history query failed: $e');
  }
}

Map<String, dynamic>? _parseHeaders(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  try {
    return jsonDecode(raw) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}
