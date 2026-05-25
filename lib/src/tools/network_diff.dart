import 'dart:async';
import 'dart:convert';

import 'package:dart_mcp/server.dart';

import '../config/capabilities.dart';
import '../state/session.dart';
import '../storage/captures_db.dart';
import '../util/body_decoder.dart';
import 'result.dart';

final networkDiffTool = Tool(
  name: 'network_diff',
  description:
      'Compare two captured requests side-by-side to see what changed: '
      'status, method, URL, response headers, and (when both bodies are '
      'utf8) a line-based body diff. Use this when investigating a '
      'regression — a request that used to work now fails, or two '
      'similar-looking requests behave differently. Also useful to confirm '
      'two requests really are identical when you suspect they are. Both '
      'ids must live in the SAME session.',
  inputSchema: Schema.object(
    properties: {
      'idA': Schema.string(description: 'First request id.'),
      'idB': Schema.string(description: 'Second request id.'),
      'sessionId': Schema.int(
        description: 'Session id (default: current live or viewed session).',
      ),
      'maxBodyLines': Schema.int(
        description: 'Max body lines to diff (default 200, hard cap 1000).',
      ),
      'maxLineLength': Schema.int(
        description:
            'Max chars per diffed line (default 2000, hard cap 8000). Longer '
            'lines get an «…+N chars» suffix.',
      ),
    },
    required: ['idA', 'idB'],
  ),
);

FutureOr<CallToolResult> networkDiff(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final caps = CapabilityConfig.instance;
  final idA = args['idA'] as String?;
  final idB = args['idB'] as String?;
  if (idA == null || idA.isEmpty || idB == null || idB.isEmpty) {
    return errorResult('Both `idA` and `idB` are required.', extra: const {
      'nextSteps': [
        'network_list — find two ids worth comparing',
        'network_search query:"..." — find ids by content',
      ],
    });
  }
  final session = Session.instance;
  final sessionId = (args['sessionId'] as int?) ?? session.effectiveSessionId;
  if (sessionId == null) {
    return errorResult('No session — attach or open one first.', extra: const {
      'nextSteps': [
        'network_attach — connect to a live app',
        'session_open id:<n> — open a past session',
      ],
    });
  }
  if (idA == idB) {
    return errorResult('idA and idB are the same — diffing a request with itself.', extra: {
      'nextSteps': const [
        'network_list — pick a different idB',
      ],
    });
  }
  final maxLinesRaw = (args['maxBodyLines'] as int?) ?? 200;
  final maxLines = maxLinesRaw <= 0 ? 200 : (maxLinesRaw > 1000 ? 1000 : maxLinesRaw);
  final maxLineLenRaw = (args['maxLineLength'] as int?) ?? 2000;
  final maxLineLen =
      maxLineLenRaw <= 0 ? 2000 : (maxLineLenRaw > 8000 ? 8000 : maxLineLenRaw);

  try {
    final dao = CapturesDao();
    final a = dao.getHttpRequest(sessionId, idA);
    final b = dao.getHttpRequest(sessionId, idB);
    if (a == null) {
      return errorResult('Request `$idA` not found in session $sessionId.', extra: {
        'sessionId': sessionId,
        'nextSteps': const [
          'network_list — list valid ids in this session',
          'session_list — confirm the session exists',
        ],
      });
    }
    if (b == null) {
      return errorResult('Request `$idB` not found in session $sessionId.', extra: {
        'sessionId': sessionId,
        'nextSteps': const [
          'network_list — list valid ids in this session',
        ],
      });
    }

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
      bodyDiff = _diffText(textA!.value, textB!.value,
          maxLines: maxLines, maxLineLength: maxLineLen);
    }

    final statusChanged = a['status_code'] != b['status_code'];
    final methodChanged = a['method'] != b['method'];
    final urlChanged = a['url'] != b['url'];
    final headerChanges = (headerDiff['added'] as Map).length +
        (headerDiff['removed'] as Map).length +
        (headerDiff['changed'] as Map).length;
    final bodyChanged = bodyDiff?['equal'] == false;
    final bodyComparable = bodyDiff?['comparable'] == true;

    final summary = _buildSummary(
      a: a,
      b: b,
      statusChanged: statusChanged,
      methodChanged: methodChanged,
      urlChanged: urlChanged,
      headerChanges: headerChanges,
      bodyChanged: bodyChanged,
      bodyComparable: bodyComparable,
    );

    final warnings = <String>[];
    if (!bodyComparable) {
      warnings.add(
        bodyA == null || bodyB == null
            ? 'Response body of one or both requests not persisted yet — body diff skipped.'
            : 'One or both response bodies are binary — body diff skipped.',
      );
    }
    if (bodyDiff?['truncated'] == true) {
      warnings.add('Body diff truncated at $maxLines lines per side.');
    }
    if (bodyDiff?['lineTruncated'] == true) {
      warnings.add('Some diffed lines exceeded $maxLineLen chars and were clipped.');
    }

    final nextSteps = <String>[];
    if (caps.isEnabled(Category.http)) {
      nextSteps.add('network_get id:"$idA" — full detail on request A');
      nextSteps.add('network_get id:"$idB" — full detail on request B');
      if (bodyChanged && bodyComparable) {
        nextSteps.add('network_replay id:"$idA" / id:"$idB" — emit curls to reproduce both');
      }
    }

    return jsonResult({
      'sessionId': sessionId,
      'summary': summary,
      'a': _summary(a),
      'b': _summary(b),
      if (statusChanged)
        'statusDiff': {'a': a['status_code'], 'b': b['status_code']},
      if (methodChanged)
        'methodDiff': {'a': a['method'], 'b': b['method']},
      if (urlChanged) 'urlDiff': {'a': a['url'], 'b': b['url']},
      'responseHeaders': headerDiff,
      'responseBody': bodyDiff ??
          {
            'comparable': false,
            'reason': bodyA == null || bodyB == null
                ? 'one or both bodies not persisted yet'
                : 'one or both bodies are not utf8 text',
          },
      if (warnings.isNotEmpty) 'warnings': warnings,
      'nextSteps': nextSteps,
    });
  } catch (e) {
    return errorResult('network_diff failed: $e', extra: {
      'sessionId': sessionId,
      'nextSteps': const [
        'Verify both ids via network_list',
      ],
    });
  }
}

String _buildSummary({
  required Map<String, Object?> a,
  required Map<String, Object?> b,
  required bool statusChanged,
  required bool methodChanged,
  required bool urlChanged,
  required int headerChanges,
  required bool bodyChanged,
  required bool bodyComparable,
}) {
  final aDesc = '${a['method']} ${_shortUrl(a['url'])}'
      ' → ${a['status_code'] ?? "n/a"}';
  final bDesc = '${b['method']} ${_shortUrl(b['url'])}'
      ' → ${b['status_code'] ?? "n/a"}';
  final diffs = <String>[];
  if (statusChanged) diffs.add('status');
  if (methodChanged) diffs.add('method');
  if (urlChanged) diffs.add('url');
  if (headerChanges > 0) diffs.add('$headerChanges header${headerChanges == 1 ? "" : "s"}');
  if (bodyChanged && bodyComparable) diffs.add('body');
  final delta = diffs.isEmpty ? 'identical' : 'differs: ${diffs.join(", ")}';
  return '$aDesc  vs  $bDesc  →  $delta.';
}

String _shortUrl(Object? url) {
  final s = url?.toString() ?? '';
  return s.length > 50 ? '${s.substring(0, 47)}...' : s;
}

Map<String, Object?> _summary(Map<String, Object?> r) {
  final dur = r['duration_us'] as int?;
  return {
    'id': r['vm_id'],
    'method': r['method'],
    'url': r['url'],
    if (r['status_code'] != null) 'statusCode': r['status_code'],
    if (dur != null) 'durationMs': dur ~/ 1000,
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

Map<String, Object?> _diffHeaders(Map<String, dynamic>? a, Map<String, dynamic>? b) {
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

Map<String, Object?> _diffText(
  String a,
  String b, {
  required int maxLines,
  required int maxLineLength,
}) {
  if (a == b) {
    return {'comparable': true, 'equal': true, 'hunks': const <String>[]};
  }
  final ls1 = a.split('\n');
  final ls2 = b.split('\n');
  final cap1 = ls1.length > maxLines ? ls1.sublist(0, maxLines) : ls1;
  final cap2 = ls2.length > maxLines ? ls2.sublist(0, maxLines) : ls2;
  final hunks = <String>[];
  var anyLineTruncated = false;
  String clip(String s) {
    if (s.length <= maxLineLength) return s;
    anyLineTruncated = true;
    return '${s.substring(0, maxLineLength)} «…+${s.length - maxLineLength} chars»';
  }
  final maxLen = cap1.length > cap2.length ? cap1.length : cap2.length;
  for (var i = 0; i < maxLen; i++) {
    final la = i < cap1.length ? cap1[i] : null;
    final lb = i < cap2.length ? cap2[i] : null;
    if (la == lb) continue;
    if (la != null) hunks.add('- ${clip(la)}');
    if (lb != null) hunks.add('+ ${clip(lb)}');
  }
  return {
    'comparable': true,
    'equal': false,
    'truncated': ls1.length > maxLines || ls2.length > maxLines,
    'lineTruncated': anyLineTruncated,
    'hunks': hunks,
  };
}
