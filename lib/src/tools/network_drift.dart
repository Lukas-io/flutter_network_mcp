import 'dart:async';
import 'dart:convert';

import 'package:dart_mcp/server.dart';

import '../storage/captures_db.dart';
import '../util/json_shape.dart';
import '../util/scope.dart';
import 'error_kind.dart';
import 'result.dart';

final networkDriftTool = Tool(
  name: 'network_drift',
  description:
      'Response-shape drift for an endpoint: compares the JSON structure of '
      'its captured responses over time and reports fields added, removed, or '
      'changed type. Answers "did the API contract change mid-session". Filter '
      'with hostContains / pathContains.',
  inputSchema: Schema.object(
    properties: {
      'hostContains': Schema.string(description: 'Host substring to match.'),
      'pathContains': Schema.string(
        description: 'Path substring to narrow to one endpoint.',
      ),
      'sessionId': Schema.int(
        description: 'Session to read. Omit to auto-resolve.',
      ),
      'appNameContains': Schema.string(
        description: 'Pick the session by app-name substring.',
      ),
      'limit': Schema.int(
        description: 'Max responses to scan (default 100, cap 500).',
      ),
    },
  ),
);

FutureOr<CallToolResult> networkDrift(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final (scope, scopeErr) = resolveScope(args);
  if (scopeErr != null) return scopeErr;
  scope!;
  final sid = scope.sessionId;
  final hostContains = args['hostContains'] as String?;
  final pathContains = (args['pathContains'] as String?)?.toLowerCase();
  final limitRaw = (args['limit'] as int?) ?? 100;
  final limit = limitRaw <= 0 ? 100 : (limitRaw > 500 ? 500 : limitRaw);

  final dao = CapturesDao();
  List<Map<String, Object?>> rows;
  try {
    rows = dao.queryHttpRequests(
      sessionId: sid,
      hostContains: hostContains,
      limit: limit,
    );
  } catch (e) {
    return errorResult('network_drift query failed: $e',
        kind: ErrorKind.internal,
        extra: const {
          'nextSteps': [
            'network_status — confirm the session is reachable',
            'network_summarize — see which endpoints have JSON traffic',
          ],
        });
  }

  final samples = <Map<String, Object?>>[];
  for (final r in rows) {
    final ct = (r['content_type'] as String?)?.toLowerCase() ?? '';
    if (!ct.contains('json')) continue;
    final path = (r['path'] as String?)?.toLowerCase() ?? '';
    if (pathContains != null && !path.contains(pathContains)) continue;
    final vmId = r['vm_id'] as String?;
    if (vmId == null) continue;
    final bytes = dao.getBody(sid, vmId, 'response');
    if (bytes == null || bytes.isEmpty) continue;
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      continue;
    }
    samples.add({
      'id': vmId,
      'path': r['path'],
      'startUs': r['start_us'],
      'shape': jsonShape(decoded),
    });
  }
  samples.sort((a, b) =>
      ((a['startUs'] as int?) ?? 0).compareTo((b['startUs'] as int?) ?? 0));

  if (samples.length < 2) {
    return jsonResult({
      'summary':
          'Not enough JSON responses to compare (${samples.length} found; '
              'need 2+).',
      'sessionId': sid,
      'scanned': samples.length,
      'nextSteps': const [
        'Drive the endpoint more, then re-call (need 2+ JSON responses)',
        'network_summarize — see which endpoints have JSON traffic',
        'network_drift pathContains:"..." — widen or change the filter',
      ],
    }, scopeSessionId: sid);
  }

  final first = samples.first['shape'] as Map<String, String>;
  Map<String, Object?>? driftAt;
  var diff = <String, Object?>{'added': [], 'removed': [], 'changed': []};
  for (final s in samples.skip(1)) {
    final d = diffShapes(first, s['shape'] as Map<String, String>);
    if ((d['added'] as List).isNotEmpty ||
        (d['removed'] as List).isNotEmpty ||
        (d['changed'] as List).isNotEmpty) {
      diff = d;
      driftAt = {
        'id': s['id'],
        'path': s['path'],
        'startTimeMs': ((s['startUs'] as int?) ?? 0) ~/ 1000,
      };
      break;
    }
  }
  final drifted = driftAt != null;
  final summary = drifted
      ? 'Response shape DRIFTED across ${samples.length} sample(s): '
          '${(diff['added'] as List).length} added, '
          '${(diff['removed'] as List).length} removed, '
          '${(diff['changed'] as List).length} type-changed field(s).'
      : 'No response-shape drift across ${samples.length} sample(s) (stable '
          'contract).';

  return jsonResult({
    'summary': summary,
    'sessionId': sid,
    'scanned': samples.length,
    'drifted': drifted,
    if (drifted) ...diff,
    if (driftAt != null) 'firstDriftAt': driftAt,
    'nextSteps': [
      if (drifted)
        'network_get id:"${driftAt['id']}" — inspect the response that changed'
      else
        'network_summarize — endpoint overview',
      'network_drift pathContains:"..." — narrow to a single endpoint',
    ],
  }, scopeSessionId: sid);
}
