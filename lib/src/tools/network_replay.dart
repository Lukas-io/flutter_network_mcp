import 'dart:async';
import 'dart:convert';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../storage/captures_db.dart';
import 'result.dart';

const _redactedHeaderNames = <String>{
  'authorization',
  'cookie',
  'proxy-authorization',
  'x-api-key',
  'x-auth-token',
};

final networkReplayTool = Tool(
  name: 'network_replay',
  description:
      'Emits a runnable curl command for a captured HTTP request. Auth-like '
      'headers (Authorization, Cookie, X-API-Key, etc.) are redacted by '
      'default — pass `redact:false` to include them verbatim.',
  inputSchema: Schema.object(
    properties: {
      'id': Schema.string(description: 'Request id.'),
      'sessionId': Schema.int(
        description: 'Session to look in. Default: current session.',
      ),
      'redact': Schema.bool(description: 'Redact auth headers (default true).'),
    },
    required: ['id'],
  ),
);

FutureOr<CallToolResult> networkReplay(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final id = args['id'] as String?;
  if (id == null || id.isEmpty) return errorResult('Missing required arg `id`.');
  final session = Session.instance;
  final sessionId = (args['sessionId'] as int?) ?? session.effectiveSessionId;
  if (sessionId == null) {
    return errorResult('No session — attach or open one first.');
  }
  final redact = (args['redact'] as bool?) ?? true;

  try {
    final dao = CapturesDao();
    final row = dao.getHttpRequest(sessionId, id);
    if (row == null) return errorResult('Request `$id` not found in session $sessionId.');
    final method = (row['method'] as String?) ?? 'GET';
    final url = (row['url'] as String?) ?? '';
    final headers = _parseHeaders(row['request_headers_json']);
    final body = dao.getBody(sessionId, id, 'request');

    final buf = StringBuffer()..write("curl -X '$method'");
    if (headers != null) {
      for (final e in headers.entries) {
        final name = e.key;
        final value = e.value is List
            ? (e.value as List).join(', ')
            : (e.value?.toString() ?? '');
        final redacted = redact && _redactedHeaderNames.contains(name.toLowerCase());
        final shown = redacted ? '<redacted>' : value;
        buf.write(" -H '${_shellEscape(name)}: ${_shellEscape(shown)}'");
      }
    }
    if (body != null && body.isNotEmpty) {
      try {
        final text = utf8.decode(body, allowMalformed: true);
        buf.write(" --data-raw '${_shellEscape(text)}'");
      } catch (_) {
        buf.write(' --data-binary @-');
      }
    }
    buf.write(" '${_shellEscape(url)}'");

    return jsonResult({
      'sessionId': sessionId,
      'id': id,
      'method': method,
      'url': url,
      'redacted': redact,
      'curl': buf.toString(),
    });
  } catch (e) {
    return errorResult('network_replay failed: $e');
  }
}

String _shellEscape(String s) => s.replaceAll(r"'", r"'\''");

Map<String, dynamic>? _parseHeaders(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  try {
    return jsonDecode(raw) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}
