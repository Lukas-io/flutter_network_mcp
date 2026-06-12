import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../config/capabilities.dart';
import '../storage/captures_db.dart';
import '../util/scope.dart';
import 'result.dart';

final correlateAtTool = Tool(
  name: 'correlate_at',
  description:
      'Correlate logs and HTTP requests around a moment in time (0.8.3). '
      'Given an anchor timestamp (e.g. the `timestampMs` of a log line you '
      'found via logs_tail), returns the log records AND HTTP requests within '
      '+/- `windowMs`, each tagged with a signed `deltaMs` from the anchor and '
      'sorted nearest-first. Answers "which request fired closest to this '
      'log?" without eyeballing two separate listings. Reads persisted data, '
      'so it works live or after session_open (live captures lag ~2s).',
  inputSchema: Schema.object(
    properties: {
      'tsMs': Schema.int(
        description:
            'Anchor timestamp, milliseconds since epoch. Usually a log '
            'entry\'s timestampMs or an HTTP request\'s startTimeMs.',
      ),
      'windowMs': Schema.int(
        description:
            'Half-width of the window in milliseconds (matches anchor +/- '
            'windowMs). Default 1000, hard cap 30000.',
      ),
      'sessionId': Schema.int(
        description:
            'Which session to read. Omit to auto-resolve: explicit view '
            '(session_open) -> sole attached session -> error if 2+ attached.',
      ),
      'appNameContains': Schema.string(
        description:
            'Alternative to sessionId: case-insensitive substring on a '
            'currently-attached app name.',
      ),
      'isolateId': Schema.string(
        description:
            'Optional: restrict both sides to one isolate. Omit to merge all.',
      ),
      'limit': Schema.int(
        description:
            'Max items returned PER SIDE (logs and requests each). Default '
            '20, hard cap 100.',
      ),
    },
    required: ['tsMs'],
  ),
);

const int _kWindowDefault = 1000;
const int _kWindowHardCap = 30000;
const int _kLimitDefault = 20;
const int _kLimitHardCap = 100;
const int _kMsgCap = 512;

FutureOr<CallToolResult> correlateAt(CallToolRequest request) async {
  final caps = CapabilityConfig.instance;
  final args = request.arguments ?? const <String, Object?>{};
  final tsMs = args['tsMs'] as int?;
  if (tsMs == null) {
    return errorResult('Missing required arg `tsMs` (anchor ms since epoch).',
        extra: const {
          'nextSteps': [
            'logs_tail — copy a log entry\'s timestampMs to anchor on',
            'network_list — copy a request\'s startTimeMs to anchor on',
          ],
        });
  }
  final (scope, scopeErr) = resolveScope(args);
  if (scopeErr != null) return scopeErr;
  scope!;

  final windowRaw = (args['windowMs'] as int?) ?? _kWindowDefault;
  final windowMs = windowRaw <= 0
      ? _kWindowDefault
      : (windowRaw > _kWindowHardCap ? _kWindowHardCap : windowRaw);
  final limitRaw = (args['limit'] as int?) ?? _kLimitDefault;
  final limit = limitRaw <= 0
      ? _kLimitDefault
      : (limitRaw > _kLimitHardCap ? _kLimitHardCap : limitRaw);
  final isolateId = args['isolateId'] as String?;

  final logsOn = caps.isEnabled(Category.logs);
  final httpOn = caps.isEnabled(Category.http);

  final dao = CapturesDao();
  final List<Map<String, Object?>> logs;
  final List<Map<String, Object?>> requests;
  try {
    logs = logsOn
        ? dao
            .logsNear(
              sessionId: scope.sessionId,
              anchorMs: tsMs,
              windowMs: windowMs,
              isolateId: isolateId,
              limit: limit,
            )
            .map((r) => _logEntry(r, tsMs))
            .toList()
        : const [];
    requests = httpOn
        ? dao
            .httpRequestsNear(
              sessionId: scope.sessionId,
              anchorMs: tsMs,
              windowMs: windowMs,
              isolateId: isolateId,
              limit: limit,
            )
            .map((r) => _requestEntry(r, tsMs))
            .toList()
        : const [];
  } catch (e) {
    return errorResult('correlate_at query failed: $e', extra: {
      'sessionId': scope.sessionId,
      'nextSteps': const [
        'network_status — confirm the session is reachable',
        'session_list — confirm the session id is correct',
      ],
    });
  }

  // Nearest item overall (across both sides), for the headline.
  Map<String, Object?>? nearest;
  String? nearestKind;
  for (final e in logs) {
    if (nearest == null ||
        (e['deltaMs'] as int).abs() < (nearest['deltaMs'] as int).abs()) {
      nearest = e;
      nearestKind = 'log';
    }
  }
  for (final e in requests) {
    if (nearest == null ||
        (e['deltaMs'] as int).abs() < (nearest['deltaMs'] as int).abs()) {
      nearest = e;
      nearestKind = 'request';
    }
  }

  final disabled = <String>[
    if (!logsOn) 'logs',
    if (!httpOn) 'http',
  ];
  final summary = (logs.isEmpty && requests.isEmpty)
      ? 'Nothing within +/-${windowMs}ms of $tsMs'
          '${disabled.isEmpty ? "" : " (${disabled.join("+")} capability disabled)"}.'
      : '${logs.length} log(s) + ${requests.length} request(s) within '
          '+/-${windowMs}ms of $tsMs. Nearest: '
          '${_nearestDesc(nearest!, nearestKind!)}.';

  final nextSteps = <String>[];
  if (logs.isEmpty && requests.isEmpty) {
    nextSteps.add('Raise windowMs (hard cap $_kWindowHardCap) to widen the search');
  } else {
    if (nearestKind == 'request' && httpOn) {
      nextSteps.add(
          'network_get id:"${nearest!['id']}" — full detail on the nearest request');
    }
    if (requests.isNotEmpty && httpOn) {
      nextSteps.add('network_replay id:"${requests.first['id']}" — reproduce the nearest request');
    }
  }

  return jsonResult({
    'scope': scope.toBlock(),
    'sessionId': scope.sessionId,
    'summary': summary,
    'anchorMs': tsMs,
    'windowMs': windowMs,
    if (disabled.isNotEmpty) 'disabledSides': disabled,
    'logs': logs,
    'requests': requests,
    'nextSteps': nextSteps,
  }, scopeSessionId: scope.sessionId);
}

Map<String, Object?> _logEntry(Map<String, Object?> r, int anchorMs) {
  final ts = (r['timestamp_ms'] as int?) ?? anchorMs;
  final msg = (r['message'] as String?) ?? '';
  final truncated = msg.length > _kMsgCap;
  return {
    'id': r['id'],
    'timestampMs': ts,
    'deltaMs': ts - anchorMs,
    'source': r['source'],
    if (r['level'] != null) 'level': r['level'],
    if (r['logger'] != null) 'loggerName': r['logger'],
    if (r['isolate_id'] != null) 'isolateId': r['isolate_id'],
    'message': truncated ? msg.substring(0, _kMsgCap) : msg,
    if (truncated) 'truncated': true,
  };
}

Map<String, Object?> _requestEntry(Map<String, Object?> r, int anchorMs) {
  final startUs = (r['start_us'] as int?) ?? (anchorMs * 1000);
  final startMs = startUs ~/ 1000;
  final durUs = r['duration_us'] as int?;
  return {
    'id': r['vm_id'],
    'timestampMs': startMs,
    'deltaMs': startMs - anchorMs,
    'method': r['method'],
    'url': r['url'],
    if (r['status_code'] != null) 'statusCode': r['status_code'],
    if (durUs != null) 'durationMs': durUs ~/ 1000,
    if (r['isolate_id'] != null) 'isolateId': r['isolate_id'],
  };
}

String _nearestDesc(Map<String, Object?> e, String kind) {
  final delta = e['deltaMs'] as int;
  final sign = delta >= 0 ? '+' : '';
  if (kind == 'request') {
    return '${e['method']} ${e['url']} ($sign${delta}ms)';
  }
  final msg = (e['message'] as String?) ?? '';
  final short = msg.length > 60 ? '${msg.substring(0, 57)}...' : msg;
  return 'log "$short" ($sign${delta}ms)';
}
