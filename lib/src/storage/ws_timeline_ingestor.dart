import 'captures_db.dart';

/// Turns dart:io `WebSocket.*` timeline events into `websocket_connections` and `websocket_messages` rows; safe to feed overlapping or re-delivered batches.
class WsTimelineIngestor {
  WsTimelineIngestor(this._dao);

  final CapturesDao _dao;
  final Map<String, String> _connKeys = {};

  /// Ingests one batch of raw trace events; [clockOffsetUs] shifts VM timeline micros onto the epoch clock HTTP rows use.
  void ingest(
    int sessionId,
    List<Map<String, Object?>> events, {
    required int clockOffsetUs,
  }) {
    final sorted = [...events]..sort((a, b) => _ts(a).compareTo(_ts(b)));
    final occurrences = <String, int>{};
    for (final e in sorted) {
      final base = _dedupBase(e);
      final n = occurrences[base] = (occurrences[base] ?? 0) + 1;
      _one(sessionId, e, _ts(e) + clockOffsetUs, '$base#$n');
    }
  }

  void _one(int sid, Map<String, Object?> e, int tsUs, String dedupKey) {
    final name = e['name'] as String? ?? '';
    final args = (e['args'] as Map?)?.cast<String, Object?>() ?? const {};
    final isolateId = args['isolateId'] as String?;
    if (name == 'WebSocket.Connect') {
      final connKey = 'connect:$isolateId:${e['id']}';
      if (e['ph'] == 'b') {
        _dao.wsConnectStarted(sid,
            connKey: connKey,
            isolateId: isolateId,
            uri: args['uri'] as String?,
            startedUs: tsUs);
      } else if (e['ph'] == 'e') {
        _dao.wsConnectFinished(sid,
            connKey: connKey,
            isolateId: isolateId,
            endUs: tsUs,
            error: args['error'] as String?,
            httpStatus: (args['httpStatusCode'] as num?)?.toInt());
      }
      return;
    }
    final connectionId = (args['connectionId'] as num?)?.toInt();
    if (connectionId == null) return;
    final connKey = _connKeyFor(sid, isolateId, connectionId, tsUs);
    final direction = args['direction'] as String?;
    switch (name) {
      case 'WebSocket.Send' || 'WebSocket.Receive':
        _dao.insertWsMessage(sid,
            connKey: connKey,
            tsUs: tsUs,
            kind: args['opcode'] as String? ?? 'unknown',
            direction: direction,
            bytes: (args['bytes'] as num?)?.toInt(),
            dedupKey: dedupKey);
      case 'WebSocket.Ping' || 'WebSocket.Pong':
        _dao.insertWsMessage(sid,
            connKey: connKey,
            tsUs: tsUs,
            kind: name == 'WebSocket.Ping' ? 'ping' : 'pong',
            direction: direction,
            bytes: (args['bytes'] as num?)?.toInt(),
            dedupKey: dedupKey);
      case 'WebSocket.Close':
        final code = (args['closeCode'] as num?)?.toInt();
        final reason = args['reason'] as String?;
        _dao.insertWsMessage(sid,
            connKey: connKey,
            tsUs: tsUs,
            kind: 'close',
            direction: direction,
            detail: [
              if (code != null) '$code',
              if (reason != null && reason.isNotEmpty) reason,
            ].join(' '),
            dedupKey: dedupKey);
        _dao.wsConnectionClosed(sid,
            connKey: connKey,
            tsUs: tsUs,
            code: code,
            reason: reason,
            closedBy: switch (direction) {
              'out' => 'app',
              'in' => 'server',
              _ => null,
            });
      case 'WebSocket.Error':
        final error = args['error'] as String? ?? 'unknown error';
        _dao.insertWsMessage(sid,
            connKey: connKey,
            tsUs: tsUs,
            kind: 'error',
            detail: error,
            dedupKey: dedupKey);
        _dao.wsConnectionError(sid, connKey: connKey, error: error);
    }
  }

  /// dart:io numbers connections per isolate but its connect event carries no number, so the first event of a new number claims the earliest connect still waiting on that isolate.
  String _connKeyFor(int sid, String? isolateId, int connectionId, int tsUs) {
    final cacheKey = '$isolateId|$connectionId';
    final cached = _connKeys[cacheKey];
    if (cached != null) return cached;
    final key = _dao.wsConnKeyFor(sid, isolateId, connectionId) ??
        _dao
            .wsBindConnection(sid,
                isolateId: isolateId,
                connectionId: connectionId,
                firstSeenUs: tsUs)
            ?.connKey ??
        _unseenConnect(sid, isolateId, connectionId);
    return _connKeys[cacheKey] = key;
  }

  String _unseenConnect(int sid, String? isolateId, int connectionId) {
    final key = 'conn:$isolateId:$connectionId';
    _dao.wsConnectionSeen(sid,
        connKey: key, isolateId: isolateId, connectionId: connectionId);
    return key;
  }

  static int _ts(Map<String, Object?> e) => (e['ts'] as num?)?.toInt() ?? 0;

  static String _dedupBase(Map<String, Object?> e) {
    final args = (e['args'] as Map?) ?? const {};
    return [
      args['isolateId'],
      e['ts'],
      e['name'],
      e['ph'],
      e['id'],
      args['connectionId'],
      args['direction'],
      args['opcode'],
      args['bytes'],
    ].join('|');
  }
}
