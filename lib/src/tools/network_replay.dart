import 'dart:async';
import 'dart:convert';

import 'package:dart_mcp/server.dart';

import '../config/capabilities.dart';
import '../storage/captures_db.dart';
import '../util/scope.dart';
import 'result.dart';

const _kDefaultBodyTruncate = 4096;
const _kMaxBodyTruncate = 262144;

final networkReplayTool = Tool(
  name: 'network_replay',
  description:
      'Emits a runnable curl command for a captured HTTP request. Sensitive '
      'headers are redacted by default (built-in set + names added via the '
      'redacted_headers tool). Request body is truncated to '
      '`bodyTruncateBytes` (default 4 KB) so the response stays context-safe. '
      'Pass `redact:false` for unredacted headers (local debugging only); '
      '`bodyTruncateBytes:0` for the full body up to 256 KB.',
  inputSchema: Schema.object(
    properties: {
      'id': Schema.string(description: 'Request id from network_list / network_search.'),
      'sessionId': Schema.int(
        description:
            'Which session the request belongs to. Omit to auto-resolve: '
            'explicit view (session_open) → sole attached session → error '
            'if 2+ attached.',
      ),
      'appNameContains': Schema.string(
        description:
            'Alternative to sessionId — case-insensitive substring on a '
            'currently-attached app name.',
      ),
      'redact': Schema.bool(
        description: 'Mask auth-like headers with <redacted> (default true). Set false only for local terminal use.',
      ),
      'bodyTruncateBytes': Schema.int(
        description:
            'Max bytes of body inlined into the curl. Default 4096, hard cap 262144. '
            'Pass 0 to use the hard cap.',
      ),
    },
    required: ['id'],
  ),
);

FutureOr<CallToolResult> networkReplay(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final caps = CapabilityConfig.instance;
  final id = args['id'] as String?;
  if (id == null || id.isEmpty) {
    return errorResult('Missing required arg `id`.', extra: const {
      'nextSteps': [
        'network_list — list captured requests and pick an id',
        'network_search query:"..." — find a request by content',
      ],
    });
  }
  final (scope, scopeErr) = resolveScope(args);
  if (scopeErr != null) return scopeErr;
  scope!;
  final sessionId = scope.sessionId;
  final redact = (args['redact'] as bool?) ?? true;
  final bodyMaxRaw = (args['bodyTruncateBytes'] as int?) ?? _kDefaultBodyTruncate;
  final bodyMax = bodyMaxRaw <= 0
      ? _kMaxBodyTruncate
      : (bodyMaxRaw > _kMaxBodyTruncate ? _kMaxBodyTruncate : bodyMaxRaw);

  try {
    final dao = CapturesDao();
    final row = dao.getHttpRequest(sessionId, id);
    if (row == null) {
      return errorResult('Request `$id` not found in session $sessionId.', extra: {
        'sessionId': sessionId,
        'nextSteps': const [
          'network_list — list valid ids in this session',
          'session_list — confirm the session exists',
        ],
      });
    }
    final method = (row['method'] as String?) ?? 'GET';
    final url = (row['url'] as String?) ?? '';
    final headers = _parseHeaders(row['request_headers_json']);
    final body = dao.getBody(sessionId, id, 'request');
    final redactedSet = redact ? dao.redactedHeaderSet() : const <String>{};

    final buf = StringBuffer()..write("curl -X '$method'");
    int headerCount = 0;
    int redactedCount = 0;
    if (headers != null) {
      for (final e in headers.entries) {
        final name = e.key;
        final value = e.value is List
            ? (e.value as List).join(', ')
            : (e.value?.toString() ?? '');
        final isRedacted = redactedSet.contains(name.toLowerCase());
        if (isRedacted) redactedCount++;
        final shown = isRedacted ? '<redacted>' : value;
        buf.write(" -H '${_shellEscape(name)}: ${_shellEscape(shown)}'");
        headerCount++;
      }
    }

    bool bodyTruncated = false;
    int? totalSize;
    bool bodyIsBinary = false;
    if (body != null && body.isNotEmpty) {
      totalSize = body.length;
      final clipped = body.length > bodyMax ? body.sublist(0, bodyMax) : body;
      bodyTruncated = body.length > bodyMax;
      try {
        final text = utf8.decode(clipped, allowMalformed: false);
        buf.write(" --data-raw '${_shellEscape(text)}'");
      } catch (_) {
        // Not valid utf8 — curl can't inline binary safely.
        buf.write(' --data-binary @-');
        bodyIsBinary = true;
      }
    }
    buf.write(" '${_shellEscape(url)}'");

    final warnings = <String>[];
    if (bodyIsBinary) {
      warnings.add(
        'Request body is binary — curl uses `--data-binary @-`; you must pipe the raw bytes in yourself.',
      );
    }
    if (bodyTruncated) {
      warnings.add(
        'Request body truncated at $bodyMax of $totalSize bytes — the curl will send a shortened body unless you raise bodyTruncateBytes.',
      );
    }
    if (!redact) {
      warnings.add('Auth headers are NOT redacted — do not share this curl externally.');
    }

    final nextSteps = <String>[];
    if (caps.isEnabled(Category.http)) {
      nextSteps.add('Paste the curl into your terminal to reproduce the request');
      nextSteps.add('network_diff idA:"$id" idB:"<other id>" — compare with another captured request');
      nextSteps.add('network_get id:"$id" — see headers + response detail');
    }

    final summary = '$method ${_shortUrl(url)} curl emitted ($headerCount header(s)'
        '${redactedCount > 0 ? ", $redactedCount redacted" : ""}'
        '${totalSize != null ? ", $totalSize-byte body" : ""}).';

    return jsonResult({
      'scope': scope.toBlock(),
      'sessionId': sessionId,
      'summary': summary,
      'id': id,
      'method': method,
      'url': url,
      'redacted': redact,
      'headerCount': headerCount,
      if (redactedCount > 0) 'redactedHeaders': redactedCount,
      if (totalSize != null) ...{
        'bodyTotalSize': totalSize,
        'bodyTruncated': bodyTruncated,
        if (bodyIsBinary) 'bodyIsBinary': true,
      },
      'curl': buf.toString(),
      if (warnings.isNotEmpty) 'warnings': warnings,
      'nextSteps': nextSteps,
    }, scopeSessionId: scope.sessionId);
  } catch (e) {
    return errorResult('network_replay failed: $e', extra: {
      'sessionId': sessionId,
      'id': id,
      'nextSteps': const [
        'network_list — confirm the id is valid',
        'network_get id:"..." — see the underlying request data',
      ],
    });
  }
}

String _shellEscape(String s) => s.replaceAll(r"'", r"'\''");

String _shortUrl(String url) =>
    url.length > 50 ? '${url.substring(0, 47)}...' : url;

Map<String, dynamic>? _parseHeaders(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  try {
    return jsonDecode(raw) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}
