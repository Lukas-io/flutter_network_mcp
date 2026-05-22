import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../config/capabilities.dart';
import '../state/session.dart';
import '../storage/captures_db.dart';
import '../util/filters.dart';
import 'result.dart';

final socketListTool = Tool(
  name: 'socket_list',
  description:
      'Lists dart:io socket statistics (TCP/UDP) for the attached app (live '
      'mode) or the viewed session (history mode). Returns address, port, '
      'byte counts, and open/closed state — NEVER payloads (sockets don\'t '
      'capture them).',
  inputSchema: Schema.object(
    properties: {
      'limit': Schema.int(description: 'Max sockets returned (default 50, hard cap 200). Newest-first by startTimeUs.'),
    },
  ),
);

FutureOr<CallToolResult> socketList(CallToolRequest request) async {
  final session = Session.instance;
  final caps = CapabilityConfig.instance;
  final args = request.arguments ?? const <String, Object?>{};
  final limit = clampLimit(args['limit'] as int?, fallback: 50, hardMax: 200);

  if (session.isViewingHistory) {
    try {
      final sid = session.viewedSessionId!;
      final rows = CapturesDao().querySockets(sessionId: sid, limit: limit);
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
        'sessionId': sid,
        'summary': summary,
        'count': sockets.length,
        if (warnings.isNotEmpty) 'warnings': warnings,
        'nextSteps': _nextSteps(caps, sockets: sockets, isLive: false),
        'sockets': sockets,
      });
    } catch (e) {
      return errorResult('history query failed: $e', extra: {
        'sessionId': session.viewedSessionId,
        'nextSteps': const [
          'session_close to return to live mode',
          'session_list to confirm the viewed session exists',
        ],
      });
    }
  }

  if (!session.isAttached) {
    return errorResult('Not attached and no session opened.', extra: const {
      'nextSteps': [
        'network_attach — connect to a live app',
        'session_open id:<n> — view a past session',
      ],
    });
  }
  if (!session.socketProfilingEnabled) {
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
    final profile = await session.vm.getSocketProfile();
    final sorted = profile.sockets.toList()
      ..sort((a, b) => b.startTime.compareTo(a.startTime));
    final clipped = sorted.take(limit).toList();
    final sockets = [
      for (final s in clipped)
        {
          'id': s.id,
          'socketType': s.socketType,
          'address': s.address,
          'port': s.port,
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
    final scannedTotal = profile.sockets.length;
    final summary = sockets.isEmpty
        ? 'No sockets in session ${session.liveSessionId} (live).'
        : '${sockets.length} socket(s) ($openCount open) in session ${session.liveSessionId} (live, newest-first)'
            '${scannedTotal > sockets.length ? "; ${scannedTotal - sockets.length} more capped by limit" : ""}.';

    final warnings = <String>[];
    if (sockets.isEmpty) {
      warnings.add(
        'Profile is empty — drive the app to open sockets (websockets / gRPC / custom TCP).',
      );
    }

    return jsonResult({
      'source': 'live',
      'sessionId': session.liveSessionId,
      'summary': summary,
      'count': sockets.length,
      'totalCaptured': scannedTotal,
      if (warnings.isNotEmpty) 'warnings': warnings,
      'nextSteps': _nextSteps(caps, sockets: sockets, isLive: true),
      'sockets': sockets,
    });
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
