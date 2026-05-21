import 'dart:async';
import 'dart:convert';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../storage/captures_db.dart';
import '../util/body_decoder.dart';
import 'result.dart';

final networkDiffTool = Tool(
  name: 'network_diff',
  description:
      'Structural diff of two captured HTTP requests. Returns header sets '
      'added/removed/changed, status code changes, and a unified body diff '
      'when both bodies are utf8-decodable. Reads from DB; both ids must be '
      'in the same session (default: current session).',
  inputSchema: Schema.object(
    properties: {
      'idA': Schema.string(description: 'First request id.'),
      'idB': Schema.string(description: 'Second request id.'),
      'sessionId': Schema.int(
        description: 'Session to look in. Default: current session.',
      ),
      'maxBodyLines': Schema.int(
        description: 'Max body lines to diff (default 200, hard cap 1000).',
      ),
    },
    required: ['idA', 'idB'],
  ),
);

FutureOr<CallToolResult> networkDiff(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final idA = args['idA'] as String?;
  final idB = args['idB'] as String?;
  if (idA == null || idA.isEmpty || idB == null || idB.isEmpty) {
    return errorResult('Both `idA` and `idB` are required.');
  }
  final session = Session.instance;
  final sessionId = (args['sessionId'] as int?) ?? session.effectiveSessionId;
  if (sessionId == null) {
    return errorResult('No session — attach or open one first.');
  }
  final maxLinesRaw = (args['maxBodyLines'] as int?) ?? 200;
  final maxLines = maxLinesRaw <= 0 ? 200 : (maxLinesRaw > 1000 ? 1000 : maxLinesRaw);

  try {
    final dao = CapturesDao();
    final a = dao.getHttpRequest(sessionId, idA);
    final b = dao.getHttpRequest(sessionId, idB);
    if (a == null) return errorResult('Request `$idA` not found in session $sessionId.');
    if (b == null) return errorResult('Request `$idB` not found in session $sessionId.');

    final headersA = _parseHeaders(a['response_headers_json']);
    final headersB = _parseHeaders(b['response_headers_json']);
    final headerDiff = _diffHeaders(headersA, headersB);

    final ctA = a['content_type'] as String?;
    final ctB = b['content_type'] as String?;
    final bodyA = dao.getBody(sessionId, idA, 'response');
    final bodyB = dao.getBody(sessionId, idB, 'response');
    final textA = bodyA == null ? null : decodeBody(bodyA, ctA, maxBytes: -1);
    final textB = bodyB == null ? null : decodeBody(bodyB, ctB, maxBytes: -1);

    Map<String, Object?>? bodyDiff;
    if (textA?.encoding == 'utf8' && textB?.encoding == 'utf8') {
      bodyDiff = _diffText(textA!.value, textB!.value, maxLines: maxLines);
    }

    return jsonResult({
      'sessionId': sessionId,
      'a': _summary(a),
      'b': _summary(b),
      'statusDiff': {
        'a': a['status_code'],
        'b': b['status_code'],
        'changed': a['status_code'] != b['status_code'],
      },
      'methodDiff': {
        'a': a['method'],
        'b': b['method'],
        'changed': a['method'] != b['method'],
      },
      'urlDiff': {
        'a': a['url'],
        'b': b['url'],
        'changed': a['url'] != b['url'],
      },
      'responseHeaders': headerDiff,
      'responseBody': bodyDiff ??
          {
            'comparable': false,
            'reason': bodyA == null || bodyB == null
                ? 'one or both bodies not persisted yet'
                : 'one or both bodies are not utf8 text',
          },
    });
  } catch (e) {
    return errorResult('network_diff failed: $e');
  }
}

Map<String, Object?> _summary(Map<String, Object?> r) {
  return {
    'id': r['vm_id'],
    'method': r['method'],
    'url': r['url'],
    'statusCode': r['status_code'],
    'durationMs': (r['duration_us'] as int?) == null
        ? null
        : ((r['duration_us'] as int) ~/ 1000),
  };
}

Map<String, dynamic>? _parseHeaders(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  try {
    return jsonDecode(raw) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

Map<String, Object?> _diffHeaders(
  Map<String, dynamic>? a,
  Map<String, dynamic>? b,
) {
  final ma = _flat(a);
  final mb = _flat(b);
  final added = <String, String>{};
  final removed = <String, String>{};
  final changed = <String, Map<String, String?>>{};
  for (final k in {...ma.keys, ...mb.keys}) {
    final va = ma[k];
    final vb = mb[k];
    if (va == null && vb != null) {
      added[k] = vb;
    } else if (va != null && vb == null) {
      removed[k] = va;
    } else if (va != vb) {
      changed[k] = {'a': va, 'b': vb};
    }
  }
  return {'added': added, 'removed': removed, 'changed': changed};
}

Map<String, String> _flat(Map<String, dynamic>? m) {
  if (m == null) return const {};
  final out = <String, String>{};
  for (final e in m.entries) {
    final v = e.value;
    if (v is List) {
      out[e.key.toLowerCase()] = v.join(', ');
    } else {
      out[e.key.toLowerCase()] = v?.toString() ?? '';
    }
  }
  return out;
}

Map<String, Object?> _diffText(String a, String b, {required int maxLines}) {
  if (a == b) {
    return {'comparable': true, 'equal': true, 'hunks': const <String>[]};
  }
  final ls1 = a.split('\n');
  final ls2 = b.split('\n');
  final cap1 = ls1.length > maxLines ? ls1.sublist(0, maxLines) : ls1;
  final cap2 = ls2.length > maxLines ? ls2.sublist(0, maxLines) : ls2;
  final hunks = <String>[];
  final maxLen = cap1.length > cap2.length ? cap1.length : cap2.length;
  for (var i = 0; i < maxLen; i++) {
    final la = i < cap1.length ? cap1[i] : null;
    final lb = i < cap2.length ? cap2[i] : null;
    if (la == lb) continue;
    if (la != null) hunks.add('- $la');
    if (lb != null) hunks.add('+ $lb');
  }
  return {
    'comparable': true,
    'equal': false,
    'truncated':
        ls1.length > maxLines || ls2.length > maxLines ? true : false,
    'hunks': hunks,
  };
}
