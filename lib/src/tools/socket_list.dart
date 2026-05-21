import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../storage/captures_db.dart';
import '../util/filters.dart';
import 'result.dart';

final socketListTool = Tool(
  name: 'socket_list',
  description:
      'Lists dart:io socket statistics for the attached app (live mode) or '
      'the viewed session (history mode). Does NOT include payloads — '
      'sockets do not capture payloads.',
  inputSchema: Schema.object(
    properties: {
      'limit': Schema.int(description: 'Max results (default 50, hard cap 200).'),
    },
  ),
);

FutureOr<CallToolResult> socketList(CallToolRequest request) async {
  final session = Session.instance;
  final args = request.arguments ?? const <String, Object?>{};
  final limit = clampLimit(args['limit'] as int?, fallback: 50, hardMax: 200);

  if (session.isViewingHistory) {
    try {
      final rows = CapturesDao().querySockets(
        sessionId: session.viewedSessionId!,
        limit: limit,
      );
      return jsonResult({
        'source': 'history',
        'sessionId': session.viewedSessionId,
        'count': rows.length,
        'sockets': [
          for (final r in rows)
            {
              'id': r['vm_id'],
              'socketType': r['socket_type'],
              'address': r['address'],
              'port': r['port'],
              'startTimeUs': r['start_us'],
              'endTimeUs': r['end_us'],
              'lastReadTimeUs': r['last_read_us'],
              'lastWriteTimeUs': r['last_write_us'],
              'readBytes': r['read_bytes'],
              'writeBytes': r['write_bytes'],
              'open': r['end_us'] == null,
            },
        ],
      });
    } catch (e) {
      return errorResult('history query failed: $e');
    }
  }

  if (!session.isAttached) {
    return errorResult('Not attached. Call network_attach first.');
  }
  if (!session.socketProfilingEnabled) {
    return errorResult('Socket profiling not enabled for this isolate.');
  }
  try {
    final profile = await session.vm.getSocketProfile();
    final sorted = profile.sockets.toList()
      ..sort((a, b) => b.startTime.compareTo(a.startTime));
    final clipped = sorted.take(limit).toList();
    return jsonResult({
      'source': 'live',
      'sessionId': session.liveSessionId,
      'count': clipped.length,
      'totalCaptured': profile.sockets.length,
      'sockets': [
        for (final s in clipped)
          {
            'id': s.id,
            'socketType': s.socketType,
            'address': s.address,
            'port': s.port,
            'startTimeUs': s.startTime,
            'endTimeUs': s.endTime,
            'lastReadTimeUs': s.lastReadTime,
            'lastWriteTimeUs': s.lastWriteTime,
            'readBytes': s.readBytes,
            'writeBytes': s.writeBytes,
            'open': s.endTime == null,
          },
      ],
    });
  } catch (e) {
    return errorResult('getSocketProfile failed: $e');
  }
}
