import 'dart:async';
import 'dart:convert';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../storage/captures_db.dart';
import 'result.dart';

const _kDefaultBodyTruncate = 4096;
const _kMaxBodyTruncate = 262144;

final networkReplayTool = Tool(
  name: 'network_replay',
  description:
      'Emits a runnable curl command for a captured HTTP request. Sensitive '
      'headers are redacted by default (built-in set + custom names added via '
      'the redacted_headers tool). Request body is truncated to '
      '`bodyTruncateBytes` (default 4 KB) so the response stays context-safe. '
      'Pass `redact:false` for unredacted headers; `bodyTruncateBytes:0` for '
      'the full body up to 256 KB.',
  inputSchema: Schema.object(
    properties: {
      'id': Schema.string(description: 'Request id.'),
      'sessionId': Schema.int(
        description: 'Session to look in. Default: current session.',
      ),
      'redact': Schema.bool(description: 'Redact auth-like headers (default true).'),
      'bodyTruncateBytes': Schema.int(
        description: 'Max bytes of body inlined into the curl. Default 4096, hard cap 262144. Pass 0 for "as much as the cap allows".',
      ),
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
  final bodyMaxRaw = (args['bodyTruncateBytes'] as int?) ?? _kDefaultBodyTruncate;
  final bodyMax = bodyMaxRaw <= 0
      ? _kMaxBodyTruncate
      : (bodyMaxRaw > _kMaxBodyTruncate ? _kMaxBodyTruncate : bodyMaxRaw);

  try {
    final dao = CapturesDao();
    final row = dao.getHttpRequest(sessionId, id);
    if (row == null) return errorResult('Request `$id` not found in session $sessionId.');
    final method = (row['method'] as String?) ?? 'GET';
    final url = (row['url'] as String?) ?? '';
    final headers = _parseHeaders(row['request_headers_json']);
    final body = dao.getBody(sessionId, id, 'request');
    final redactedSet = redact ? dao.redactedHeaderSet() : const <String>{};

    final buf = StringBuffer()..write("curl -X '$method'");
    if (headers != null) {
      for (final e in headers.entries) {
        final name = e.key;
        final value = e.value is List
            ? (e.value as List).join(', ')
            : (e.value?.toString() ?? '');
        final shown = redactedSet.contains(name.toLowerCase()) ? '<redacted>' : value;
        buf.write(" -H '${_shellEscape(name)}: ${_shellEscape(shown)}'");
      }
    }

    bool bodyTruncated = false;
    int? totalSize;
    if (body != null && body.isNotEmpty) {
      totalSize = body.length;
      final clipped = body.length > bodyMax ? body.sublist(0, bodyMax) : body;
      bodyTruncated = body.length > bodyMax;
      try {
        final text = utf8.decode(clipped, allowMalformed: true);
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
      if (totalSize != null) ...{
        'bodyTotalSize': totalSize,
        'bodyTruncated': bodyTruncated,
      },
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
