import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../config/capabilities.dart';
import '../state/session.dart';
import '../storage/captures_db.dart';
import '../util/scope.dart';
import 'error_kind.dart';
import 'result.dart';

final socketGetTool = Tool(
  name: 'socket_get',
  description:
      'One socket\'s stats by id (from socket_list). Byte counts + lifetime '
      'only; no payloads.',
  inputSchema: Schema.object(
    properties: {
      'id': Schema.string(description: 'Socket id from socket_list.'),
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
            'Restrict to one isolate (id from network_status). Omit to '
            'auto-resolve.',
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
    return errorResult('Missing required arg `id`.',
        kind: ErrorKind.badArgument,
        extra: const {
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
      return errorResult('Socket `$id` not found in session $sid.',
          kind: ErrorKind.notFound,
          extra: {
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
      'Socket profiling not enabled for any of this session\'s isolates.',
      kind: ErrorKind.capabilityDisabled,
      extra: const {
        'nextSteps': [
          'network_status — confirm socketProfilingEnabled',
          'Re-attach (some embedders need a fresh session)',
        ],
      },
    );
  }

  final isolateFilter = args['isolateId'] as String?;
  String? resolvedIsolateId = isolateFilter;
  if (resolvedIsolateId == null) {
    final dbRow = CapturesDao().getSocket(scope.sessionId, id);
    resolvedIsolateId = dbRow?['isolate_id'] as String?;
  }
  final candidateIsolates = resolvedIsolateId != null
      ? [resolvedIsolateId]
      : [for (final iso in attached.vm.httpProfilingIsolates) iso.id];

  dynamic foundSocket;
  String? foundIsolateId;
  var isoFailures = 0;
  Object? lastError;
  for (final isoId in candidateIsolates) {
    try {
      final profile = await attached.vm.getSocketProfileForIsolate(isoId);
      for (final s in profile.sockets) {
        if (s.id == id) {
          foundSocket = s;
          foundIsolateId = isoId;
          break;
        }
      }
      if (foundSocket != null) break;
    } catch (e) {
      isoFailures++;
      lastError = e;
    }
  }

  if (foundSocket == null) {
    final dbRow = CapturesDao().getSocket(scope.sessionId, id);
    final allFailed =
        candidateIsolates.isNotEmpty && isoFailures == candidateIsolates.length;
    if (dbRow != null) {
      return _historySuccess(
        scope,
        dbRow,
        caps,
        degradedReason: allFailed
            ? 'Live socket read failed ($lastError); returned the persisted '
                'DB copy instead.'
            : 'Socket is no longer in the live profile (closed/collected); '
                'returned the persisted DB copy.',
      );
    }
    return errorResult(
      allFailed
          ? 'Live socket read failed for every isolate: $lastError'
          : 'Socket id `$id` not found in current live profile.',
      kind: allFailed ? ErrorKind.unresponsiveVm : ErrorKind.notFound,
      extra: {
        'triedIsolates': candidateIsolates,
        'nextSteps': const [
          'socket_list — list currently-captured ids',
          'session_open id:<n> — try a past session if this id is from history',
        ],
      },
    );
  }

  final s = foundSocket;
  final summary = _summary(
    socketType: s.socketType as String?,
    address: s.address as String?,
    port: s.port as int?,
    readBytes: s.readBytes as int?,
    writeBytes: s.writeBytes as int?,
    isOpen: s.endTime == null,
  );
  return jsonResult({
    'source': 'live',
    'scope': scope.toBlock(),
    'sessionId': scope.sessionId,
    if (foundIsolateId != null) 'isolateId': foundIsolateId,
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
    'nextSteps': _nextSteps(caps, isOpen: s.endTime == null, address: s.address as String?),
  }, scopeSessionId: scope.sessionId, scopeNote: scope.note);
}

CallToolResult _historySuccess(
  Scope scope,
  Map<String, Object?> row,
  CapabilityConfig caps, {
  String? degradedReason,
}) {
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
    'source': degradedReason != null ? 'live-db-fallback' : 'history',
    if (degradedReason != null) 'degraded': true,
    'scope': scope.toBlock(),
    'sessionId': sid,
    if (row['isolate_id'] != null) 'isolateId': row['isolate_id'],
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
    if (degradedReason != null) 'warnings': [degradedReason],
    'nextSteps': _nextSteps(caps, isOpen: isOpen, address: row['address'] as String?),
  }, scopeSessionId: scope.sessionId, scopeNote: scope.note);
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
