import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../storage/captures_db.dart';
import '../util/path_template.dart';
import '../util/scope.dart';
import 'error_kind.dart';
import 'result.dart';

final networkSummarizeTool = Tool(
  name: 'network_summarize',
  description:
      'One digest row per endpoint: count, status distribution, p50/p95 '
      'latency, error rate, by (method, host, pathTemplate). Path templates '
      'collapse ids (/api/users/42 and /91 -> /api/users/N). Good first call '
      'after network_status for the session shape; cheaper than network_list.',
  inputSchema: Schema.object(
    properties: {
      'sessionId': Schema.int(
        description:
            'Session to read from. Omit to auto-resolve (the sole attached '
            'session, or the one you opened).',
      ),
      'appNameContains': Schema.string(
        description: 'Pick the session by app-name substring instead of sessionId.',
      ),
      'sinceMs': Schema.int(
        description: 'Window in ms. Default 3600000 (1h); 0 for the whole session.',
      ),
      'hostContains': Schema.string(
        description: 'Case-insensitive host substring.',
      ),
      'limit': Schema.int(
        description: 'Max endpoint rows (default 50, cap 200).',
      ),
      'minCount': Schema.int(
        description: 'Drop endpoints with fewer than this many requests. Default 1.',
      ),
    },
  ),
);

const int _kRawRowsCap = 10000;
const int _kLimitDefault = 50;
const int _kLimitHardCap = 200;
const int _kSinceMsDefault = 3600000;

FutureOr<CallToolResult> networkSummarize(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final (scope, scopeErr) = resolveScope(args);
  if (scopeErr != null) return scopeErr;
  scope!;

  final sinceMsRaw = (args['sinceMs'] as int?) ?? _kSinceMsDefault;
  final hostContains = args['hostContains'] as String?;
  final limitRaw = (args['limit'] as int?) ?? _kLimitDefault;
  final limit = limitRaw <= 0
      ? _kLimitDefault
      : (limitRaw > _kLimitHardCap ? _kLimitHardCap : limitRaw);
  final minCount = (args['minCount'] as int?) ?? 1;

  final nowUs = DateTime.now().microsecondsSinceEpoch;
  final sinceUs = sinceMsRaw <= 0 ? null : nowUs - (sinceMsRaw * 1000);

  final List<Map<String, Object?>> rows;
  try {
    rows = CapturesDao().queryHttpRequests(
      sessionId: scope.sessionId,
      sinceUs: sinceUs,
      hostContains: hostContains,
      limit: _kRawRowsCap,
    );
  } catch (e) {
    return errorResult('network_summarize query failed: $e',
        kind: ErrorKind.internal,
        extra: {
          'sessionId': scope.sessionId,
          'nextSteps': const [
            'network_status — confirm the session is reachable',
            'network_list — try the raw list to isolate the issue',
          ],
        });
  }

  final endpoints = summarizeRequests(rows, minCount: minCount);
  final truncated = endpoints.length > limit;
  final returned = truncated ? endpoints.sublist(0, limit) : endpoints;

  final windowDesc = sinceMsRaw <= 0
      ? 'entire session'
      : _formatWindow(sinceMsRaw);
  final hostDesc = hostContains == null || hostContains.isEmpty
      ? ''
      : ' (host contains "$hostContains")';
  final hitRawCap = rows.length >= _kRawRowsCap;

  final summary = endpoints.isEmpty
      ? 'No HTTP requests captured over $windowDesc$hostDesc.'
      : '${endpoints.length} distinct endpoint(s) over $windowDesc$hostDesc, '
          '${rows.length} total request(s) considered'
          '${hitRawCap ? " (raw-row cap of $_kRawRowsCap hit — widen sinceMs or hostContains)" : ""}.';

  final nextSteps = <String>[];
  if (returned.isEmpty) {
    nextSteps.add(
      'Drive the app to generate traffic, then re-run network_summarize.',
    );
  } else {
    final top = returned.first;
    final topEndpoint = top['endpoint'] as String;
    nextSteps.add(
      'network_list hostContains:"${top['host']}" — drill into the '
      'busiest endpoint ($topEndpoint, ${top['count']} request(s))',
    );
    final hasErrors = returned.any((e) => (e['errorRate'] as double) > 0);
    if (hasErrors) {
      nextSteps.add(
        'alerts_drain — at least one endpoint has a non-zero error rate; '
        'check for queued alerts',
      );
    }
    if (truncated) {
      nextSteps.add(
        'Raise `limit` (max $_kLimitHardCap) or narrow `hostContains` to '
        'see endpoints ${limit + 1}–${endpoints.length}',
      );
    }
  }

  return jsonResult({
    'scope': scope.toBlock(),
    'sessionId': scope.sessionId,
    'summary': summary,
    'window': windowDesc,
    'rawRowsConsidered': rows.length,
    if (hitRawCap) 'rawRowsCapHit': true,
    'count': returned.length,
    if (truncated) 'truncatedAt': limit,
    'endpoints': returned,
    'nextSteps': nextSteps,
  });
}

/// Aggregates raw `http_requests` rows into one digest entry per
/// (method, host, pathTemplate) bucket. Visible for testing.
///
/// Returns endpoints sorted by count desc. Each entry is the JSON shape
/// `network_summarize` emits.
///
/// Row contract: each map must expose `method` (String?), `host`
/// (String?), `path` (String?), `status_code` (int?), `duration_us`
/// (int?). Extra columns are ignored.
List<Map<String, Object?>> summarizeRequests(
  List<Map<String, Object?>> rows, {
  int minCount = 1,
}) {
  final buckets = <String, _Bucket>{};
  for (final row in rows) {
    final method = ((row['method'] as String?) ?? '').toUpperCase();
    final host = (row['host'] as String?) ?? '';
    final rawPath = (row['path'] as String?) ?? '';
    final template = pathTemplate(rawPath);
    final key = '$method|$host|$template';
    final bucket = buckets.putIfAbsent(
      key,
      () => _Bucket(host: host, method: method, template: template),
    );
    bucket.add(row);
  }
  final out = buckets.values
      .where((b) => b.count >= minCount)
      .map((b) => b.toJson())
      .toList()
    ..sort((a, b) => (b['count'] as int).compareTo(a['count'] as int));
  return out;
}

class _Bucket {
  _Bucket({
    required this.host,
    required this.method,
    required this.template,
  });

  final String host;
  final String method;
  final String template;

  int count = 0;
  int errorCount = 0;
  final Map<int, int> statusDist = {};
  final List<int> durationsMs = [];

  void add(Map<String, Object?> row) {
    count++;
    final status = row['status_code'] as int?;
    if (status != null) {
      statusDist[status] = (statusDist[status] ?? 0) + 1;
      if (status >= 400) errorCount++;
    } else {
      errorCount++;
      statusDist[0] = (statusDist[0] ?? 0) + 1;
    }
    final dur = row['duration_us'] as int?;
    if (dur != null && dur >= 0) {
      durationsMs.add(dur ~/ 1000);
    }
  }

  Map<String, Object?> toJson() {
    final sortedDur = [...durationsMs]..sort();
    final p50 = _percentile(sortedDur, 0.50);
    final p95 = _percentile(sortedDur, 0.95);
    final errorRate = count == 0 ? 0.0 : errorCount / count;
    final endpoint = '$method ${host.isEmpty ? "" : host}$template'.trim();
    final statusOut = <String, int>{};
    for (final entry in statusDist.entries) {
      statusOut[entry.key == 0 ? 'error' : entry.key.toString()] = entry.value;
    }
    return {
      'endpoint': endpoint,
      'method': method,
      'host': host,
      'pathTemplate': template,
      'count': count,
      'statusDist': statusOut,
      'p50LatencyMs': p50,
      'p95LatencyMs': p95,
      'errorRate': double.parse(errorRate.toStringAsFixed(4)),
    };
  }
}

int? _percentile(List<int> sorted, double p) {
  if (sorted.isEmpty) return null;
  if (sorted.length == 1) return sorted.first;
  final rank = (sorted.length * p).floor();
  final clamped = rank < 0
      ? 0
      : (rank >= sorted.length ? sorted.length - 1 : rank);
  return sorted[clamped];
}

String _formatWindow(int sinceMs) {
  if (sinceMs < 60000) return '${sinceMs}ms';
  if (sinceMs < 3600000) return '${(sinceMs / 60000).round()}m';
  return '${(sinceMs / 3600000).round()}h';
}
