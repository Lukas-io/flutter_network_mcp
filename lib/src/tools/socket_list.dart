import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../config/capabilities.dart';
import '../state/session.dart';
import '../storage/captures_db.dart';
import '../util/filters.dart';
import '../util/scope.dart';
import 'result.dart';

final socketListTool = Tool(
  name: 'socket_list',
  description:
      'Lists dart:io socket stats (TCP/UDP): address, port, byte counts, '
      'open/closed. Never payloads (sockets do not capture them).',
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
      'isolateId': Schema.string(
        description:
            'Restrict to one isolate (id from network_status). Omit to merge '
            'all isolates.',
      ),
      'limit': Schema.int(description: 'Max sockets (default 50, cap 200).'),
    },
  ),
);

FutureOr<CallToolResult> socketList(CallToolRequest request) async {
  final caps = CapabilityConfig.instance;
  final args = request.arguments ?? const <String, Object?>{};
  final (scope, scopeErr) = resolveScope(args);
  if (scopeErr != null) return scopeErr;
  scope!;

  final isolateFilter = args['isolateId'] as String?;
  final limit = clampLimit(args['limit'] as int?, fallback: 50, hardMax: 200);

  if (!scope.isLive) {
    try {
      final sid = scope.sessionId;
      final rows = CapturesDao().querySockets(
        sessionId: sid,
        isolateId: isolateFilter,
        limit: limit,
      );
      final sockets = [for (final r in rows) _historySocket(r)];
      final openCount = sockets.where((s) => s['open'] == true).length;
      final summary = sockets.isEmpty
          ? 'No sockets captured in session $sid (history).'
          : '${sockets.length} socket(s) in session $sid ($openCount open).';
      final warnings = <String>[];
      if (sockets.isEmpty) {
        warnings.add(
          'Session may not have used dart:io sockets, or socket profiling was disabled at attach time.',
        );
      }
      return jsonResult({
        'source': 'history',
        'scope': scope.toBlock(),
        'sessionId': sid,
        'summary': summary,
        'count': sockets.length,
        if (warnings.isNotEmpty) 'warnings': warnings,
        'nextSteps': _nextSteps(caps, sockets: sockets, isLive: false),
        'sockets': sockets,
      }, scopeSessionId: scope.sessionId);
    } catch (e) {
      return errorResult('history query failed: $e', extra: {
        'sessionId': scope.sessionId,
        'nextSteps': const [
          'session_close to return to live mode',
          'session_list to confirm the viewed session exists',
        ],
      });
    }
  }

  final attached = SessionRegistry.instance.attachedById(scope.sessionId)!;
  if (!attached.socketProfilingEnabled) {
    return errorResult(
      'Socket profiling is not enabled for this isolate (platform may not support it).',
      extra: const {
        'nextSteps': [
          'network_status — confirm socketProfilingEnabled in attach result',
          'Re-attach the app (some embedders need a fresh session)',
        ],
      },
    );
  }
  try {
    // Multi-isolate live read: iterate every HTTP-profiling isolate (each
    // has its own socket profile), or the one named by [isolateFilter].
    final isolateIds = isolateFilter == null
        ? [for (final iso in attached.vm.httpProfilingIsolates) iso.id]
        : [isolateFilter];
    final perIsolate = <(dynamic, String)>[];
    int scannedTotal = 0;
    for (final isoId in isolateIds) {
      try {
        final profile = await attached.vm.getSocketProfileForIsolate(isoId);
        scannedTotal += profile.sockets.length;
        for (final s in profile.sockets) {
          perIsolate.add((s, isoId));
        }
      } catch (_) {/* per-isolate skip */}
    }
    perIsolate.sort(
      (a, b) => (b.$1.startTime as int).compareTo(a.$1.startTime as int),
    );
    final clipped = perIsolate.take(limit).toList();
    final sockets = [
      for (final (s, isoId) in clipped)
        {
          'id': s.id,
          'socketType': s.socketType,
          'address': s.address,
          'port': s.port,
          'isolateId': isoId,
          'startTimeUs': s.startTime,
          if (s.endTime != null) 'endTimeUs': s.endTime,
          if (s.lastReadTime != null) 'lastReadTimeUs': s.lastReadTime,
          if (s.lastWriteTime != null) 'lastWriteTimeUs': s.lastWriteTime,
          'readBytes': s.readBytes,
          'writeBytes': s.writeBytes,
          'open': s.endTime == null,
        },
    ];
    final openCount = sockets.where((s) => s['open'] == true).length;
    final summary = sockets.isEmpty
        ? 'No sockets in session ${scope.sessionId} (live).'
        : '${sockets.length} socket(s) ($openCount open) in session ${scope.sessionId} (live, newest-first)'
            '${scannedTotal > sockets.length ? "; ${scannedTotal - sockets.length} more capped by limit" : ""}.';

    final warnings = <String>[];
    if (sockets.isEmpty) {
      warnings.add(
        'Profile is empty — drive the app to open sockets (websockets / gRPC / custom TCP).',
      );
    }

    return jsonResult({
      'source': 'live',
      'scope': scope.toBlock(),
      'sessionId': scope.sessionId,
      'summary': summary,
      'count': sockets.length,
      'totalCaptured': scannedTotal,
      if (warnings.isNotEmpty) 'warnings': warnings,
      'nextSteps': _nextSteps(caps, sockets: sockets, isLive: true),
      'sockets': sockets,
    }, scopeSessionId: scope.sessionId);
  } catch (e) {
    return errorResult('getSocketProfile failed: $e', extra: const {
      'nextSteps': [
        'network_status — check zombie-DTD state',
        'network_detach then network_attach — full reset',
      ],
    });
  }
}

Map<String, Object?> _historySocket(Map<String, Object?> r) {
  return {
    'id': r['vm_id'],
    'socketType': r['socket_type'],
    'address': r['address'],
    'port': r['port'],
    if (r['isolate_id'] != null) 'isolateId': r['isolate_id'],
    if (r['start_us'] != null) 'startTimeUs': r['start_us'],
    if (r['end_us'] != null) 'endTimeUs': r['end_us'],
    if (r['last_read_us'] != null) 'lastReadTimeUs': r['last_read_us'],
    if (r['last_write_us'] != null) 'lastWriteTimeUs': r['last_write_us'],
    'readBytes': r['read_bytes'],
    'writeBytes': r['write_bytes'],
    'open': r['end_us'] == null,
  };
}

List<String> _nextSteps(
  CapabilityConfig caps, {
  required List<Map<String, Object?>> sockets,
  required bool isLive,
}) {
  final steps = <String>[];
  if (sockets.isNotEmpty) {
    steps.add('socket_get id:"${sockets.first['id']}" — detail on the newest socket');
    if (caps.isEnabled(Category.http)) {
      steps.add('network_list — see HTTP traffic alongside (HTTP uses TCP sockets too)');
    }
  } else if (isLive) {
    steps.add('Drive the app to open WebSocket / gRPC / custom TCP connections');
    if (caps.isEnabled(Category.http)) {
      steps.add('network_list — your traffic may be plain HTTP (no socket-level data)');
    }
  } else {
    steps.add('session_close — return to live mode and try this session\'s app');
  }
  return steps;
}
