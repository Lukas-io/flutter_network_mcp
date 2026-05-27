import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../config/capabilities.dart';
import '../state/session.dart';
import '../storage/captures_db.dart';
import '../util/scope.dart';
import 'result.dart';

final socketGetTool = Tool(
  name: 'socket_get',
  description:
      'Returns one socket\'s statistics by id (from socket_list). Aggregate '
      'byte counts + lifetime timing only — sockets do not capture payloads.',
  inputSchema: Schema.object(
    properties: {
      'id': Schema.string(description: 'Socket id from socket_list.'),
      'sessionId': Schema.int(
        description:
            'Which session the socket belongs to. Omit to auto-resolve.',
      ),
      'appNameContains': Schema.string(
        description:
            'Alternative to sessionId — case-insensitive substring on a '
            'currently-attached app name.',
      ),
    },
    required: ['id'],
  ),
);

FutureOr<CallToolResult> socketGet(CallToolRequest request) async {
  final caps = CapabilityConfig.instance;
  final args = request.arguments ?? const <String, Object?>{};
  final id = args['id'] as String?;
  if (id == null || id.isEmpty) {
    return errorResult('Missing required arg `id`.', extra: const {
      'nextSteps': [
        'socket_list — list current sockets and pick one',
      ],
    });
  }
  final (scope, scopeErr) = resolveScope(args);
  if (scopeErr != null) return scopeErr;
  scope!;

  if (!scope.isLive) {
    final sid = scope.sessionId;
    final row = CapturesDao().getSocket(sid, id);
    if (row == null) {
      return errorResult('Socket `$id` not found in session $sid.', extra: {
        'sessionId': sid,
        'nextSteps': const [
          'socket_list — list valid socket ids in this session',
          'session_list — confirm the session id is correct',
        ],
      });
    }
    return _historySuccess(scope, row, caps);
  }

  final attached = SessionRegistry.instance.attachedById(scope.sessionId)!;
  if (!attached.socketProfilingEnabled) {
    return errorResult(
      'Socket profiling not enabled for this isolate.',
      extra: const {
        'nextSteps': [
          'network_status — confirm socketProfilingEnabled',
          'Re-attach (some embedders need a fresh session)',
        ],
      },
    );
  }
  try {
    final profile = await attached.vm.getSocketProfile();
    final found = profile.sockets.where((s) => s.id == id).toList();
    if (found.isEmpty) {
      return errorResult('Socket id `$id` not found in current live profile.', extra: const {
        'nextSteps': [
          'socket_list — list currently-captured ids',
          'session_open id:<n> — try a past session if this id is from history',
        ],
      });
    }
    final s = found.first;
    final summary = _summary(
      socketType: s.socketType,
      address: s.address,
      port: s.port,
      readBytes: s.readBytes,
      writeBytes: s.writeBytes,
      isOpen: s.endTime == null,
    );
    return jsonResult({
      'source': 'live',
      'scope': scope.toBlock(),
      'sessionId': scope.sessionId,
      'summary': summary,
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
      'nextSteps': _nextSteps(caps, isOpen: s.endTime == null, address: s.address),
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

CallToolResult _historySuccess(Scope scope, Map<String, Object?> row, CapabilityConfig caps) {
  final sid = scope.sessionId;
  final isOpen = row['end_us'] == null;
  final summary = _summary(
    socketType: row['socket_type'] as String?,
    address: row['address'] as String?,
    port: row['port'] as int?,
    readBytes: row['read_bytes'] as int?,
    writeBytes: row['write_bytes'] as int?,
    isOpen: isOpen,
  );
  return jsonResult({
    'source': 'history',
    'scope': scope.toBlock(),
    'sessionId': sid,
    'summary': summary,
    'id': row['vm_id'],
    'socketType': row['socket_type'],
    'address': row['address'],
    'port': row['port'],
    if (row['start_us'] != null) 'startTimeUs': row['start_us'],
    if (row['end_us'] != null) 'endTimeUs': row['end_us'],
    if (row['last_read_us'] != null) 'lastReadTimeUs': row['last_read_us'],
    if (row['last_write_us'] != null) 'lastWriteTimeUs': row['last_write_us'],
    'readBytes': row['read_bytes'],
    'writeBytes': row['write_bytes'],
    'open': isOpen,
    'nextSteps': _nextSteps(caps, isOpen: isOpen, address: row['address'] as String?),
  });
}

String _summary({
  required String? socketType,
  required String? address,
  required int? port,
  required int? readBytes,
  required int? writeBytes,
  required bool isOpen,
}) {
  final endpoint = address != null && port != null ? '$address:$port' : (address ?? 'unknown');
  return '${(socketType ?? "socket").toUpperCase()} $endpoint — '
      '${readBytes ?? 0} bytes read, ${writeBytes ?? 0} bytes written '
      '(${isOpen ? "open" : "closed"}).';
}

List<String> _nextSteps(CapabilityConfig caps, {required bool isOpen, required String? address}) {
  final steps = <String>[];
  steps.add('socket_list — see sibling sockets in this session');
  if (caps.isEnabled(Category.http) && address != null) {
    steps.add('network_list hostContains:"$address" — check correlated HTTP traffic');
  }
  if (isOpen) {
    steps.add('Re-call this tool later to see updated read/write bytes (socket is still open)');
  }
  return steps;
}
