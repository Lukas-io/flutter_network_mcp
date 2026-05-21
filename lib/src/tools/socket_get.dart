import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../storage/captures_db.dart';
import 'result.dart';

final socketGetTool = Tool(
  name: 'socket_get',
  description: 'Returns one socket\'s statistics by id.',
  inputSchema: Schema.object(
    properties: {'id': Schema.string(description: 'Socket id from socket_list.')},
    required: ['id'],
  ),
);

FutureOr<CallToolResult> socketGet(CallToolRequest request) async {
  final session = Session.instance;
  final args = request.arguments ?? const <String, Object?>{};
  final id = args['id'] as String?;
  if (id == null || id.isEmpty) return errorResult('Missing required arg `id`.');

  if (session.isViewingHistory) {
    final sid = session.viewedSessionId!;
    final row = CapturesDao().getSocket(sid, id);
    if (row == null) return errorResult('Socket `$id` not found in session $sid.');
    return jsonResult({
      'source': 'history',
      'sessionId': sid,
      'id': row['vm_id'],
      'socketType': row['socket_type'],
      'address': row['address'],
      'port': row['port'],
      'startTimeUs': row['start_us'],
      'endTimeUs': row['end_us'],
      'lastReadTimeUs': row['last_read_us'],
      'lastWriteTimeUs': row['last_write_us'],
      'readBytes': row['read_bytes'],
      'writeBytes': row['write_bytes'],
      'open': row['end_us'] == null,
    });
  }

  if (!session.isAttached) {
    return errorResult('Not attached. Call network_attach first.');
  }
  if (!session.socketProfilingEnabled) {
    return errorResult('Socket profiling not enabled for this isolate.');
  }
  try {
    final profile = await session.vm.getSocketProfile();
    final found = profile.sockets.where((s) => s.id == id).toList();
    if (found.isEmpty) {
      return errorResult('Socket id `$id` not found in current profile.');
    }
    final s = found.first;
    return jsonResult({
      'source': 'live',
      'sessionId': session.liveSessionId,
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
    });
  } catch (e) {
    return errorResult('getSocketProfile failed: $e');
  }
}
