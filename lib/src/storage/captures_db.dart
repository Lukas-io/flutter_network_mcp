import 'dart:convert';
// ignore: unused_import — Uint8List used in BLOB type check below.
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:vm_service/vm_service.dart';

import 'database.dart';

/// Typed accessors for the captures database. Holds no state of its own —
/// all calls go directly through [CapturesDatabase.instance].
class CapturesDao {
  sql.Database get _db => CapturesDatabase.instance.raw;

  // ----- sessions -----

  int createSession({
    required String? appName,
    required String? vmServiceUri,
    required String? isolateId,
    required String? projectPath,
  }) {
    _db.execute(
      'INSERT INTO sessions(started_at, app_name, vm_service_uri, isolate_id, project_path) VALUES (?,?,?,?,?)',
      [DateTime.now().millisecondsSinceEpoch, appName, vmServiceUri, isolateId, projectPath],
    );
    return _db.lastInsertRowId;
  }

  void endSession(int sessionId) {
    _db.execute(
      'UPDATE sessions SET ended_at=? WHERE id=? AND ended_at IS NULL',
      [DateTime.now().millisecondsSinceEpoch, sessionId],
    );
  }

  /// Repoints an existing session row at a new VM service URI / isolate after
  /// a hot-restart reattach (issue #16), so captures keep flowing into the
  /// same session id instead of starting a new row each restart.
  void repointSession(
    int id, {
    required String? vmServiceUri,
    required String? isolateId,
  }) {
    _db.execute(
      'UPDATE sessions SET vm_service_uri=?, isolate_id=? WHERE id=?',
      [vmServiceUri, isolateId, id],
    );
  }

  List<Map<String, Object?>> listSessions({
    String? projectPath,
    String? appNameContains,
    int? sinceMs,
    int limit = 20,
  }) {
    final clauses = <String>[];
    final params = <Object?>[];
    if (projectPath != null) {
      clauses.add('project_path = ?');
      params.add(projectPath);
    }
    if (appNameContains != null && appNameContains.isNotEmpty) {
      clauses.add('LOWER(app_name) LIKE ?');
      params.add('%${appNameContains.toLowerCase()}%');
    }
    if (sinceMs != null) {
      clauses.add('started_at >= ?');
      params.add(sinceMs);
    }
    final where = clauses.isEmpty ? '' : ' WHERE ${clauses.join(' AND ')}';
    final rows = _db.select(
      'SELECT s.id, s.started_at, s.ended_at, s.app_name, s.vm_service_uri, s.isolate_id, s.project_path, s.note, '
      '(SELECT COUNT(*) FROM http_requests h WHERE h.session_id=s.id) AS http_count, '
      '(SELECT COUNT(*) FROM socket_events sk WHERE sk.session_id=s.id) AS socket_count, '
      '(SELECT COUNT(*) FROM log_records l WHERE l.session_id=s.id) AS log_count '
      'FROM sessions s$where ORDER BY started_at DESC LIMIT ?',
      [...params, limit],
    );
    return rows.map(_rowToMap).toList();
  }

  Map<String, Object?>? getSession(int id) {
    final rows = _db.select('SELECT * FROM sessions WHERE id=?', [id]);
    if (rows.isEmpty) return null;
    return _rowToMap(rows.first);
  }

  /// Like [getSession] but joins COUNT subqueries for http_count,
  /// socket_count, log_count, alert_count. Use when you need per-session
  /// counts for one specific id (dry-run summaries, export, etc.).
  Map<String, Object?>? getSessionWithCounts(int id) {
    final rows = _db.select(
      'SELECT s.*, '
      '(SELECT COUNT(*) FROM http_requests h WHERE h.session_id=s.id) AS http_count, '
      '(SELECT COUNT(*) FROM socket_events sk WHERE sk.session_id=s.id) AS socket_count, '
      '(SELECT COUNT(*) FROM log_records l WHERE l.session_id=s.id) AS log_count, '
      '(SELECT COUNT(*) FROM alerts a WHERE a.session_id=s.id) AS alert_count '
      'FROM sessions s WHERE s.id=?',
      [id],
    );
    if (rows.isEmpty) return null;
    return _rowToMap(rows.first);
  }

  // ----- http -----

  /// Upserts a request summary. Returns true if a new row was inserted.
  ///
  /// [isolateId] (Phase 8 / v4) tags the row with the isolate that produced
  /// the request. NULL is preserved for back-compat with pre-v4 rows.
  /// On UPDATE the isolate_id is `COALESCE(excluded.isolate_id, isolate_id)`
  /// — once tagged, a row keeps its isolate even if a follow-up upsert
  /// arrives without the tag.
  bool upsertHttpRequest(
    int sessionId,
    HttpProfileRequest r, {
    String? isolateId,
  }) {
    final headersReq = r.request != null && !r.request!.hasError
        ? jsonEncode(r.request!.headers ?? {})
        : null;
    final headersResp = r.response != null && !r.response!.hasError
        ? jsonEncode(r.response!.headers ?? {})
        : null;
    final contentType = _firstHeader(r.response?.headers, 'content-type') ??
        _firstHeader(r.request?.headers, 'content-type');
    final endUs = r.endTime?.microsecondsSinceEpoch;
    final startUs = r.startTime.microsecondsSinceEpoch;
    final durationUs = endUs == null ? null : endUs - startUs;

    final before = _db.select(
      'SELECT 1 FROM http_requests WHERE session_id=? AND vm_id=?',
      [sessionId, r.id],
    );
    final isNew = before.isEmpty;

    _db.execute(
      'INSERT INTO http_requests(session_id, vm_id, isolate_id, method, url, host, path, status_code, reason_phrase, start_us, end_us, duration_us, request_size, response_size, content_type, request_headers_json, response_headers_json, has_error) '
      'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) '
      'ON CONFLICT(session_id, vm_id) DO UPDATE SET '
      '  isolate_id=COALESCE(excluded.isolate_id, isolate_id), '
      '  method=excluded.method, url=excluded.url, host=excluded.host, path=excluded.path, '
      '  status_code=excluded.status_code, reason_phrase=excluded.reason_phrase, '
      '  end_us=excluded.end_us, duration_us=excluded.duration_us, '
      '  request_size=excluded.request_size, response_size=excluded.response_size, '
      '  content_type=excluded.content_type, '
      '  request_headers_json=excluded.request_headers_json, '
      '  response_headers_json=excluded.response_headers_json, '
      '  has_error=excluded.has_error',
      [
        sessionId,
        r.id,
        isolateId,
        r.method,
        r.uri.toString(),
        r.uri.host,
        r.uri.path,
        r.response?.statusCode,
        r.response?.reasonPhrase,
        startUs,
        endUs,
        durationUs,
        r.request?.hasError == true ? null : r.request?.contentLength,
        r.response?.hasError == true ? null : r.response?.contentLength,
        contentType,
        headersReq,
        headersResp,
        ((r.request?.hasError ?? false) || (r.response?.hasError ?? false)) ? 1 : 0,
      ],
    );
    return isNew;
  }

  /// Stores both request and response bodies (when present) and marks the
  /// http_requests row as bodies_fetched.
  void storeBodies(int sessionId, HttpProfileRequest r) {
    if (r.requestBody != null && r.requestBody!.isNotEmpty) {
      _writeBody(sessionId, r.id, 'request', r.requestBody!);
    }
    if (r.responseBody != null && r.responseBody!.isNotEmpty) {
      _writeBody(sessionId, r.id, 'response', r.responseBody!);
    }
    _db.execute(
      'UPDATE http_requests SET bodies_fetched=1 WHERE session_id=? AND vm_id=?',
      [sessionId, r.id],
    );
  }

  void _writeBody(int sessionId, String vmId, String which, Uint8List bytes) {
    _db.execute(
      'INSERT OR REPLACE INTO http_bodies(session_id, vm_id, which, bytes, size) VALUES (?,?,?,?,?)',
      [sessionId, vmId, which, bytes, bytes.length],
    );
  }

  /// One entry returned by [pendingBodyFetches] — carries the vm_id plus the
  /// isolate_id the request was originally captured from so the writer can
  /// route the body backfill RPC to the right isolate (v4+), and whether the
  /// request was response-complete (`end_us` set) at query time.
  ///
  /// `isolateId` is nullable: pre-v4 rows and rows captured before isolate
  /// tagging stay NULL. The writer falls back to the first known isolate.
  /// (Record-typed alias so the public DAO surface stays explicit.)
  ///
  /// Complete requests (`end_us` set) are always eligible. Response-incomplete
  /// requests become eligible once they are older than [staleBeforeUs] and
  /// still under [maxAttempts]; this rescues chunked / gzip responses the
  /// dart:io profiler never marks complete, without spinning forever on
  /// genuinely body-less or transport-invisible ones. Pass `staleBeforeUs:
  /// null` to restore the legacy "complete rows only" behaviour.
  // ignore: library_private_types_in_public_api
  List<({String vmId, String? isolateId, bool isComplete})> pendingBodyFetches(
    int sessionId, {
    int limit = 50,
    int? staleBeforeUs,
    int maxAttempts = 3,
  }) {
    final rows = _db.select(
      'SELECT vm_id, isolate_id, (end_us IS NOT NULL) AS is_complete '
      'FROM http_requests '
      'WHERE session_id=? AND bodies_fetched=0 AND ('
      '  end_us IS NOT NULL '
      '  OR (? IS NOT NULL AND start_us IS NOT NULL AND start_us < ? '
      '      AND body_fetch_attempts < ?)'
      ') '
      'ORDER BY (end_us IS NULL), COALESCE(end_us, start_us) ASC LIMIT ?',
      [sessionId, staleBeforeUs, staleBeforeUs, maxAttempts, limit],
    );
    return [
      for (final r in rows)
        (
          vmId: r['vm_id'] as String,
          isolateId: r['isolate_id'] as String?,
          isComplete: (r['is_complete'] as int? ?? 0) != 0,
        ),
    ];
  }

  /// Marks a request's bodies as terminally fetched (success, or a complete
  /// request that genuinely has no body, e.g. 204 / HEAD) so it leaves the
  /// backfill queue.
  void markBodiesFetched(int sessionId, String vmId) {
    _db.execute(
      'UPDATE http_requests SET bodies_fetched=1 WHERE session_id=? AND vm_id=?',
      [sessionId, vmId],
    );
  }

  /// Records a failed/empty backfill attempt for a response-incomplete request
  /// so [pendingBodyFetches] eventually stops re-polling it.
  void bumpBodyFetchAttempt(int sessionId, String vmId) {
    _db.execute(
      'UPDATE http_requests SET body_fetch_attempts = body_fetch_attempts + 1 '
      'WHERE session_id=? AND vm_id=?',
      [sessionId, vmId],
    );
  }

  List<Map<String, Object?>> queryHttpRequests({
    required int sessionId,
    int? sinceUs,
    List<String>? methods,
    String? hostContains,
    int? statusMin,
    int? statusMax,
    String? isolateId,
    int limit = 50,
  }) {
    final clauses = <String>['session_id = ?'];
    final params = <Object?>[sessionId];
    if (sinceUs != null) {
      clauses.add('start_us > ?');
      params.add(sinceUs);
    }
    if (methods != null && methods.isNotEmpty) {
      final placeholders = List.filled(methods.length, '?').join(',');
      clauses.add('UPPER(method) IN ($placeholders)');
      params.addAll(methods.map((m) => m.toUpperCase()));
    }
    if (hostContains != null && hostContains.isNotEmpty) {
      clauses.add('LOWER(host) LIKE ?');
      params.add('%${hostContains.toLowerCase()}%');
    }
    if (statusMin != null) {
      clauses.add('status_code >= ?');
      params.add(statusMin);
    }
    if (statusMax != null) {
      clauses.add('status_code <= ?');
      params.add(statusMax);
    }
    if (isolateId != null && isolateId.isNotEmpty) {
      clauses.add('isolate_id = ?');
      params.add(isolateId);
    }
    final rows = _db.select(
      'SELECT * FROM http_requests WHERE ${clauses.join(' AND ')} ORDER BY start_us DESC LIMIT ?',
      [...params, limit],
    );
    return rows.map(_rowToMap).toList();
  }

  Map<String, Object?>? getHttpRequest(int sessionId, String vmId) {
    final rows = _db.select(
      'SELECT * FROM http_requests WHERE session_id=? AND vm_id=?',
      [sessionId, vmId],
    );
    if (rows.isEmpty) return null;
    return _rowToMap(rows.first);
  }

  Uint8List? getBody(int sessionId, String vmId, String which) {
    final rows = _db.select(
      'SELECT bytes FROM http_bodies WHERE session_id=? AND vm_id=? AND which=?',
      [sessionId, vmId, which],
    );
    if (rows.isEmpty) return null;
    final raw = rows.first['bytes'];
    if (raw is Uint8List) return raw;
    if (raw is List<int>) return Uint8List.fromList(raw);
    return null;
  }

  // ----- sockets -----

  void upsertSocket(
    int sessionId,
    SocketStatistic s, {
    String? isolateId,
  }) {
    _db.execute(
      'INSERT INTO socket_events(session_id, vm_id, isolate_id, socket_type, address, port, start_us, end_us, last_read_us, last_write_us, read_bytes, write_bytes) '
      'VALUES (?,?,?,?,?,?,?,?,?,?,?,?) '
      'ON CONFLICT(session_id, vm_id) DO UPDATE SET '
      '  isolate_id=COALESCE(excluded.isolate_id, isolate_id), '
      '  end_us=excluded.end_us, last_read_us=excluded.last_read_us, last_write_us=excluded.last_write_us, '
      '  read_bytes=excluded.read_bytes, write_bytes=excluded.write_bytes',
      [
        sessionId,
        s.id,
        isolateId,
        s.socketType,
        s.address,
        s.port,
        s.startTime,
        s.endTime,
        s.lastReadTime,
        s.lastWriteTime,
        s.readBytes,
        s.writeBytes,
      ],
    );
  }

  List<Map<String, Object?>> querySockets({
    required int sessionId,
    String? isolateId,
    int limit = 50,
  }) {
    final clauses = <String>['session_id = ?'];
    final params = <Object?>[sessionId];
    if (isolateId != null && isolateId.isNotEmpty) {
      clauses.add('isolate_id = ?');
      params.add(isolateId);
    }
    final rows = _db.select(
      'SELECT * FROM socket_events WHERE ${clauses.join(' AND ')} ORDER BY start_us DESC LIMIT ?',
      [...params, limit],
    );
    return rows.map(_rowToMap).toList();
  }

  Map<String, Object?>? getSocket(int sessionId, String vmId) {
    final rows = _db.select(
      'SELECT * FROM socket_events WHERE session_id=? AND vm_id=?',
      [sessionId, vmId],
    );
    if (rows.isEmpty) return null;
    return _rowToMap(rows.first);
  }

  // ----- logs -----

  int insertLog({
    required int sessionId,
    required int timestampMs,
    required String source,
    int? level,
    String? logger,
    required String message,
    String? error,
    String? stackTrace,
    String? isolateId,
  }) {
    _db.execute(
      'INSERT INTO log_records(session_id, isolate_id, timestamp_ms, source, level, logger, message, error, stack_trace) VALUES (?,?,?,?,?,?,?,?,?)',
      [sessionId, isolateId, timestampMs, source, level, logger, message, error, stackTrace],
    );
    return _db.lastInsertRowId;
  }

  List<Map<String, Object?>> queryLogs({
    required int sessionId,
    int? sinceId,
    int? levelMin,
    String? loggerContains,
    List<String>? messageContains,
    String? source,
    String? isolateId,
    int limit = 100,
  }) {
    final clauses = <String>['session_id = ?'];
    final params = <Object?>[sessionId];
    if (sinceId != null) {
      clauses.add('id > ?');
      params.add(sinceId);
    }
    if (levelMin != null) {
      clauses.add('(level IS NULL OR level >= ?)');
      params.add(levelMin);
    }
    if (loggerContains != null && loggerContains.isNotEmpty) {
      clauses.add('LOWER(logger) LIKE ?');
      params.add('%${loggerContains.toLowerCase()}%');
    }
    final msgTerms = messageContains
            ?.where((t) => t.trim().isNotEmpty)
            .map((t) => t.toLowerCase())
            .toList() ??
        const [];
    if (msgTerms.isNotEmpty) {
      final ors = List.filled(msgTerms.length, 'LOWER(message) LIKE ?');
      clauses.add('(${ors.join(' OR ')})');
      params.addAll(msgTerms.map((t) => '%$t%'));
    }
    if (source != null && source.isNotEmpty) {
      clauses.add('source = ?');
      params.add(source);
    }
    if (isolateId != null && isolateId.isNotEmpty) {
      clauses.add('isolate_id = ?');
      params.add(isolateId);
    }
    final rows = _db.select(
      'SELECT * FROM log_records WHERE ${clauses.join(' AND ')} ORDER BY id DESC LIMIT ?',
      [...params, limit],
    );
    return rows.map(_rowToMap).toList();
  }

  /// Log records within +/- [windowMs] of [anchorMs], nearest first (#18).
  /// Reads persisted `log_records`, so it works for both live and history.
  List<Map<String, Object?>> logsNear({
    required int sessionId,
    required int anchorMs,
    required int windowMs,
    String? isolateId,
    int limit = 20,
  }) {
    final clauses = <String>[
      'session_id = ?',
      'timestamp_ms IS NOT NULL',
      'timestamp_ms BETWEEN ? AND ?',
    ];
    final params = <Object?>[sessionId, anchorMs - windowMs, anchorMs + windowMs];
    if (isolateId != null && isolateId.isNotEmpty) {
      clauses.add('isolate_id = ?');
      params.add(isolateId);
    }
    final rows = _db.select(
      'SELECT * FROM log_records WHERE ${clauses.join(' AND ')} '
      'ORDER BY ABS(timestamp_ms - ?) ASC LIMIT ?',
      [...params, anchorMs, limit],
    );
    return rows.map(_rowToMap).toList();
  }

  /// HTTP requests whose start time is within +/- [windowMs] of [anchorMs],
  /// nearest first (#18). `start_us` is microseconds; the window is converted.
  List<Map<String, Object?>> httpRequestsNear({
    required int sessionId,
    required int anchorMs,
    required int windowMs,
    String? isolateId,
    int limit = 20,
  }) {
    final anchorUs = anchorMs * 1000;
    final clauses = <String>['session_id = ?', 'start_us BETWEEN ? AND ?'];
    final params = <Object?>[
      sessionId,
      (anchorMs - windowMs) * 1000,
      (anchorMs + windowMs) * 1000,
    ];
    if (isolateId != null && isolateId.isNotEmpty) {
      clauses.add('isolate_id = ?');
      params.add(isolateId);
    }
    final rows = _db.select(
      'SELECT * FROM http_requests WHERE ${clauses.join(' AND ')} '
      'ORDER BY ABS(start_us - ?) ASC LIMIT ?',
      [...params, anchorUs, limit],
    );
    return rows.map(_rowToMap).toList();
  }

  // ----- tool usage analytics (#79, Phase 1) -----

  /// Records one tool call. Privacy-safe by construction: [argKeys] are the
  /// parameter NAMES the agent passed, never their values; no URLs / hosts /
  /// bodies / log text are stored.
  void insertToolEvent({
    required int tsMs,
    required String correlationId,
    required String tool,
    required String outcome,
    List<String>? argKeys,
    int? durationMs,
    int? resultBytes,
  }) {
    _db.execute(
      'INSERT INTO tool_events(ts_ms, correlation_id, tool, outcome, arg_keys, '
      'duration_ms, result_bytes) VALUES (?,?,?,?,?,?,?)',
      [
        tsMs,
        correlationId,
        tool,
        outcome,
        argKeys == null ? null : jsonEncode(argKeys),
        durationMs,
        resultBytes,
      ],
    );
  }

  int toolEventCount() {
    final r = _db.select('SELECT COUNT(*) AS c FROM tool_events');
    return (r.first['c'] as int?) ?? 0;
  }

  /// Per-(tool, outcome) counts for the `usage` transparency dump.
  List<Map<String, Object?>> toolEventCounts({int? sinceMs}) {
    if (sinceMs == null) {
      return _db
          .select(
            'SELECT tool, outcome, COUNT(*) AS count FROM tool_events '
            'GROUP BY tool, outcome ORDER BY count DESC',
          )
          .map(_rowToMap)
          .toList();
    }
    return _db
        .select(
          'SELECT tool, outcome, COUNT(*) AS count FROM tool_events '
          'WHERE ts_ms >= ? GROUP BY tool, outcome ORDER BY count DESC',
          [sinceMs],
        )
        .map(_rowToMap)
        .toList();
  }

  /// Most-recent raw events for `usage show`.
  List<Map<String, Object?>> recentToolEvents({int? sinceMs, int limit = 50}) {
    if (sinceMs == null) {
      return _db
          .select('SELECT * FROM tool_events ORDER BY id DESC LIMIT ?', [limit])
          .map(_rowToMap)
          .toList();
    }
    return _db
        .select(
          'SELECT * FROM tool_events WHERE ts_ms >= ? ORDER BY id DESC LIMIT ?',
          [sinceMs, limit],
        )
        .map(_rowToMap)
        .toList();
  }

  /// All events (capped), ordered by (correlation_id, id), so the analytics
  /// layer can compute per-tool stats AND consecutive-tool transitions in one
  /// pass (#79 Phase 2, `usage_stats`).
  List<Map<String, Object?>> allToolEvents({int? sinceMs, int limit = 50000}) {
    if (sinceMs == null) {
      return _db
          .select(
            'SELECT correlation_id, tool, outcome, duration_ms, result_bytes '
            'FROM tool_events ORDER BY correlation_id, id LIMIT ?',
            [limit],
          )
          .map(_rowToMap)
          .toList();
    }
    return _db
        .select(
          'SELECT correlation_id, tool, outcome, duration_ms, result_bytes '
          'FROM tool_events WHERE ts_ms >= ? ORDER BY correlation_id, id LIMIT ?',
          [sinceMs, limit],
        )
        .map(_rowToMap)
        .toList();
  }

  /// Events with `id` strictly greater than [afterId], ordered by
  /// (correlation_id, id) so the rollup builder can compute per-tool stats
  /// AND consecutive-tool transitions in one pass. Carries `id` + `ts_ms`
  /// so the usage shipper (#79 Phase 3) can advance its high-watermark and
  /// stamp the rollup window. Pass `afterId: 0` to read from the start.
  List<Map<String, Object?>> toolEventsAfterId({
    required int afterId,
    int limit = 50000,
  }) {
    return _db
        .select(
          'SELECT id, ts_ms, correlation_id, tool, outcome, duration_ms, '
          'result_bytes FROM tool_events WHERE id > ? '
          'ORDER BY correlation_id, id LIMIT ?',
          [afterId, limit],
        )
        .map(_rowToMap)
        .toList();
  }

  // ----- alerts -----

  /// Inserts or merges an alert.
  ///
  /// Dedup happens by [signature]: if a pending (non-drained) alert with
  /// the same `(session_id, signature)` already exists, that row's
  /// `occurrence_count` is incremented, `last_seen_ms` advanced, and
  /// `last_source_id` updated to the new event's source. Severity is
  /// bumped only when the new event is more severe than the existing
  /// row (highest-seen wins).
  ///
  /// If no pending alert with this signature exists, a fresh row is
  /// inserted at `occurrence_count = 1`. Drained rows don't merge — once
  /// the agent has acknowledged a batch, a new occurrence starts a new
  /// row, so the count semantically means "events seen since last drain."
  ///
  /// Returns `true` when a NEW row was inserted, `false` when an existing
  /// row was incremented OR when the legacy
  /// `UNIQUE(session_id, kind, source_id)` constraint deduped a literal
  /// duplicate source event.
  bool insertAlert({
    required int sessionId,
    required String severity,
    required String kind,
    required String title,
    required String signature,
    String? detail,
    String? sourceKind,
    String? sourceId,
    int? tsMs,
  }) {
    final ts = tsMs ?? DateTime.now().millisecondsSinceEpoch;

    final existing = _db.select(
      'SELECT id, severity FROM alerts '
      'WHERE session_id = ? AND signature = ? AND drained = 0 LIMIT 1',
      [sessionId, signature],
    );

    if (existing.isNotEmpty) {
      final row = existing.first;
      final existingSeverity = row['severity'] as String;
      final escalated =
          _severityRank(severity) > _severityRank(existingSeverity)
              ? severity
              : existingSeverity;
      _db.execute(
        'UPDATE alerts SET '
        '  occurrence_count = occurrence_count + 1, '
        '  last_seen_ms = ?, '
        '  last_source_id = ?, '
        '  severity = ? '
        'WHERE id = ?',
        [ts, sourceId, escalated, row['id']],
      );
      return false;
    }

    try {
      _db.execute(
        'INSERT INTO alerts(session_id, ts_ms, severity, kind, title, '
        'detail, source_kind, source_id, signature, occurrence_count, '
        'last_seen_ms, last_source_id) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)',
        [sessionId, ts, severity, kind, title, detail, sourceKind,
         sourceId, signature, ts, sourceId],
      );
      return true;
    } on sql.SqliteException catch (e) {
      // The legacy UNIQUE(session_id, kind, source_id) constraint catches
      // the rare race where the same source event delivers twice (e.g. a
      // duplicate VM-service tick). Treat as already-handled.
      if (e.extendedResultCode == 2067) return false;
      rethrow;
    }
  }

  /// Sum of `occurrence_count` across pending alerts matching the filter.
  /// Differs from [pendingAlertCount] which returns DISTINCT-row count —
  /// `pendingAlertEventCount` reflects raw event volume.
  int pendingAlertEventCount({int? sessionId, String? severityMin}) {
    final clauses = <String>['drained=0'];
    final params = <Object?>[];
    if (sessionId != null) {
      clauses.add('session_id = ?');
      params.add(sessionId);
    }
    if (severityMin != null) {
      final rank = _severityRank(severityMin);
      clauses.add(_severityRankSql('severity', '>=', rank));
    }
    final rows = _db.select(
      'SELECT COALESCE(SUM(occurrence_count), 0) AS n FROM alerts '
      'WHERE ${clauses.join(' AND ')}',
      params,
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  List<Map<String, Object?>> peekAlerts({
    int? sessionId,
    String? severityMin,
    int limit = 20,
  }) {
    return _selectAlerts(
      sessionId: sessionId,
      severityMin: severityMin,
      limit: limit,
      undrainedOnly: true,
    );
  }

  List<Map<String, Object?>> drainAlerts({
    int? sessionId,
    String? severityMin,
    int limit = 50,
  }) {
    final rows = _selectAlerts(
      sessionId: sessionId,
      severityMin: severityMin,
      limit: limit,
      undrainedOnly: true,
    );
    if (rows.isEmpty) return rows;
    final ids = rows.map((r) => r['id'] as int).toList();
    final placeholders = List.filled(ids.length, '?').join(',');
    _db.execute('UPDATE alerts SET drained=1 WHERE id IN ($placeholders)', ids);
    return rows;
  }

  int pendingAlertCount({int? sessionId, String? severityMin}) {
    final clauses = <String>['drained=0'];
    final params = <Object?>[];
    if (sessionId != null) {
      clauses.add('session_id = ?');
      params.add(sessionId);
    }
    if (severityMin != null) {
      final rank = _severityRank(severityMin);
      clauses.add(_severityRankSql('severity', '>=', rank));
    }
    final rows = _db.select(
      'SELECT COUNT(*) AS n FROM alerts WHERE ${clauses.join(' AND ')}',
      params,
    );
    return rows.first['n'] as int;
  }

  List<Map<String, Object?>> _selectAlerts({
    int? sessionId,
    String? severityMin,
    int limit = 50,
    bool undrainedOnly = true,
  }) {
    final clauses = <String>[];
    final params = <Object?>[];
    if (undrainedOnly) clauses.add('drained=0');
    if (sessionId != null) {
      clauses.add('session_id = ?');
      params.add(sessionId);
    }
    if (severityMin != null) {
      final rank = _severityRank(severityMin);
      clauses.add(_severityRankSql('severity', '>=', rank));
    }
    final where = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    final rows = _db.select(
      'SELECT * FROM alerts $where ORDER BY ts_ms DESC LIMIT ?',
      [...params, limit],
    );
    return rows.map(_rowToMap).toList();
  }

  /// Cross-session lookup for the dedup signature. Returns prior
  /// occurrences of [signature] in OTHER sessions (excluding the current
  /// one), newest-first. Each entry exposes `sessionId`, `startedAtMs`,
  /// `appName`, and the session's `note` so the agent can surface a
  /// "you've seen this before, here's what you wrote about it"
  /// breadcrumb on a new alert.
  ///
  /// [limit] caps the result so a long-running install with a recurring
  /// bug doesn't return a hundred prior occurrences.
  List<Map<String, Object?>> priorOccurrencesForSignature({
    required String signature,
    required int excludeSessionId,
    int limit = 3,
  }) {
    final rows = _db.select(
      'SELECT a.session_id AS session_id, s.started_at AS started_at, '
      '       s.app_name AS app_name, s.note AS note '
      'FROM alerts a '
      'JOIN sessions s ON a.session_id = s.id '
      'WHERE a.signature = ? AND a.session_id != ? '
      'GROUP BY a.session_id '
      'ORDER BY s.started_at DESC '
      'LIMIT ?',
      [signature, excludeSessionId, limit],
    );
    return rows.map(_rowToMap).toList();
  }

  static int _severityRank(String s) {
    switch (s.toLowerCase()) {
      case 'info':
        return 1;
      case 'warning':
        return 2;
      case 'error':
        return 3;
      case 'critical':
        return 4;
      default:
        throw ArgumentError('Unknown severity "$s".');
    }
  }

  static String _severityRankSql(String col, String op, int rank) {
    // SQLite CASE expression: maps severity string → numeric for comparison.
    return '(CASE $col '
        '''WHEN 'critical' THEN 4 '''
        '''WHEN 'error' THEN 3 '''
        '''WHEN 'warning' THEN 2 '''
        '''WHEN 'info' THEN 1 '''
        'ELSE 0 END) $op $rank';
  }

  // ----- ignored hosts -----

  bool addIgnoredHost(String host, {String? reason}) {
    final before = _db.select('SELECT 1 FROM ignored_hosts WHERE host=?', [host]);
    final isNew = before.isEmpty;
    _db.execute(
      'INSERT OR REPLACE INTO ignored_hosts(host, added_at, reason) VALUES (?,?,?)',
      [host, DateTime.now().millisecondsSinceEpoch, reason],
    );
    return isNew;
  }

  bool removeIgnoredHost(String host) {
    final before = _db.select('SELECT 1 FROM ignored_hosts WHERE host=?', [host]);
    if (before.isEmpty) return false;
    _db.execute('DELETE FROM ignored_hosts WHERE host=?', [host]);
    return true;
  }

  List<Map<String, Object?>> listIgnoredHosts() {
    final rows = _db.select(
      'SELECT host, added_at, reason FROM ignored_hosts ORDER BY host',
    );
    return rows.map(_rowToMap).toList();
  }

  Set<String> ignoredHostSet() {
    final rows = _db.select('SELECT host FROM ignored_hosts');
    return {for (final r in rows) r['host'] as String};
  }

  // ----- session note -----

  void setSessionNote(int sessionId, String? note) {
    _db.execute('UPDATE sessions SET note=? WHERE id=?', [note, sessionId]);
  }

  // ----- FTS5 search -----

  /// Indexes a (utf8-decoded) request/response body pair into the FTS table.
  /// Pass `null` for empty bodies. Idempotent on (session_id, vm_id).
  void indexForSearch({
    required int sessionId,
    required String vmId,
    required String url,
    String? requestText,
    String? responseText,
    String? isolateId,
  }) {
    final existing = _db.select(
      'SELECT rowid FROM http_search_map WHERE session_id=? AND vm_id=?',
      [sessionId, vmId],
    );
    if (existing.isNotEmpty) {
      final rowid = existing.first['rowid'] as int;
      _db.execute('DELETE FROM http_search WHERE rowid=?', [rowid]);
      _db.execute(
        'INSERT INTO http_search(rowid, url, content_request, content_response) VALUES (?,?,?,?)',
        [rowid, url, requestText ?? '', responseText ?? ''],
      );
      // Update isolate_id if the row was missing it (e.g. first indexed
      // before isolate tagging arrived) — COALESCE preserves an existing
      // tag rather than overwriting with NULL.
      _db.execute(
        'UPDATE http_search_map SET isolate_id = COALESCE(?, isolate_id) '
        'WHERE session_id=? AND vm_id=?',
        [isolateId, sessionId, vmId],
      );
      return;
    }
    _db.execute(
      'INSERT INTO http_search(url, content_request, content_response) VALUES (?,?,?)',
      [url, requestText ?? '', responseText ?? ''],
    );
    final rowid = _db.lastInsertRowId;
    _db.execute(
      'INSERT INTO http_search_map(rowid, session_id, vm_id, isolate_id) VALUES (?,?,?,?)',
      [rowid, sessionId, vmId, isolateId],
    );
  }

  List<Map<String, Object?>> searchRequests({
    required String query,
    int? sessionId,
    String which = 'any',
    String? isolateId,
    int limit = 20,
  }) {
    // Wrap the user query as an FTS5 phrase so characters like '-', ':', '('
    // don't get parsed as FTS5 operators. Anyone wanting raw operator syntax
    // (AND/OR/NEAR) can pre-quote pieces themselves; this only protects the
    // default case. Double-quote characters in the query are doubled to escape.
    final phrase = '"${query.replaceAll('"', '""')}"';
    final String matchExpr;
    switch (which) {
      case 'request':
        matchExpr = 'content_request:$phrase';
        break;
      case 'response':
        matchExpr = 'content_response:$phrase';
        break;
      case 'url':
        matchExpr = 'url:$phrase';
        break;
      case 'any':
      default:
        matchExpr = phrase;
    }
    const matchClause = 'http_search MATCH ?';
    final params = <Object?>[matchExpr];
    String sessionFilter = '';
    if (sessionId != null) {
      sessionFilter = ' AND m.session_id = ?';
      params.add(sessionId);
    }
    String isolateFilter = '';
    if (isolateId != null && isolateId.isNotEmpty) {
      isolateFilter = ' AND m.isolate_id = ?';
      params.add(isolateId);
    }
    params.add(limit);
    final rows = _db.select(
      '''
      SELECT
        m.session_id AS session_id,
        m.vm_id      AS vm_id,
        r.method     AS method,
        r.url        AS url,
        r.status_code AS status_code,
        snippet(http_search, -1, '«', '»', '…', 12) AS snippet,
        bm25(http_search) AS rank
      FROM http_search
      JOIN http_search_map m ON m.rowid = http_search.rowid
      LEFT JOIN http_requests r
        ON r.session_id = m.session_id AND r.vm_id = m.vm_id
      WHERE $matchClause$sessionFilter$isolateFilter
      ORDER BY rank LIMIT ?
      ''',
      params,
    );
    return rows.map(_rowToMap).toList();
  }

  /// Cross-session FTS5 search used by `network_correlate` (Phase 12).
  ///
  /// For each [sessionIds] entry, runs the same FTS5 match used by
  /// [searchRequests] but capped per-session BEFORE we union the results.
  /// That way one noisy session can't drown the others' matches when the
  /// caller is looking for cross-app correlations (e.g. an originator +
  /// receiver pair). Returns rows grouped by session in the order
  /// [sessionIds] lists them — the tool layer pairs them up.
  ///
  /// [pattern] is phrase-quoted automatically (same convention as
  /// [searchRequests]). [which] picks the FTS column to match against.
  /// [perSessionLimit] is a hard ceiling on rows returned per session.
  List<Map<String, Object?>> correlateAcrossSessions({
    required List<int> sessionIds,
    required String pattern,
    String which = 'any',
    int perSessionLimit = 100,
  }) {
    if (sessionIds.isEmpty) return const [];
    final phrase = '"${pattern.replaceAll('"', '""')}"';
    final String matchExpr;
    switch (which) {
      case 'request':
        matchExpr = 'content_request:$phrase';
        break;
      case 'response':
        matchExpr = 'content_response:$phrase';
        break;
      case 'url':
        matchExpr = 'url:$phrase';
        break;
      case 'any':
      default:
        matchExpr = phrase;
    }
    final out = <Map<String, Object?>>[];
    for (final sid in sessionIds) {
      final rows = _db.select(
        '''
        SELECT
          m.session_id AS session_id,
          m.vm_id      AS vm_id,
          m.isolate_id AS isolate_id,
          r.method     AS method,
          r.url        AS url,
          r.host       AS host,
          r.path       AS path,
          r.status_code AS status_code,
          r.start_us   AS start_us,
          r.end_us     AS end_us,
          snippet(http_search, -1, '«', '»', '…', 12) AS snippet,
          bm25(http_search) AS rank
        FROM http_search
        JOIN http_search_map m ON m.rowid = http_search.rowid
        LEFT JOIN http_requests r
          ON r.session_id = m.session_id AND r.vm_id = m.vm_id
        WHERE http_search MATCH ? AND m.session_id = ?
        ORDER BY r.start_us ASC LIMIT ?
        ''',
        [matchExpr, sid, perSessionLimit],
      );
      out.addAll(rows.map(_rowToMap));
    }
    return out;
  }

  // ----- session maintenance -----

  /// Deletes a session and (via CASCADE) all its requests, bodies, sockets,
  /// logs, alerts, and FTS index rows.
  bool deleteSession(int sessionId) {
    final exists = _db.select('SELECT 1 FROM sessions WHERE id=?', [sessionId]);
    if (exists.isEmpty) return false;
    // Manually drop FTS rows since SQLite FTS5 doesn't honor FK cascades.
    _db.execute(
      'DELETE FROM http_search WHERE rowid IN (SELECT rowid FROM http_search_map WHERE session_id=?)',
      [sessionId],
    );
    _db.execute('DELETE FROM http_search_map WHERE session_id=?', [sessionId]);
    _db.execute('DELETE FROM sessions WHERE id=?', [sessionId]);
    return true;
  }

  /// Drops captured BLOB bodies (request + response) for matching requests.
  /// Keeps the http_requests metadata row intact.
  /// [olderThanMs] is millis-since-epoch; requests with start_us older than
  /// `olderThanMs * 1000` lose their bodies.
  int purgeBodies({int? sessionId, int? olderThanMs}) {
    final (where, params, _) = _bodyPurgeWhere(sessionId, olderThanMs);
    final before = _db
        .select('SELECT COUNT(*) AS n FROM http_bodies$where', params)
        .first['n'] as int;
    if (before == 0) return 0;
    _db.execute('DELETE FROM http_bodies$where', params);
    if (sessionId != null) {
      _db.execute(
        'UPDATE http_requests SET bodies_fetched=0 WHERE session_id=?',
        [sessionId],
      );
    } else {
      _db.execute('UPDATE http_requests SET bodies_fetched=0');
    }
    return before;
  }

  /// Dry-run count + total bytes for [purgeBodies] with the same filters.
  /// Returns `{rowCount, totalBytes}`.
  Map<String, int> countPurgeableBodies({int? sessionId, int? olderThanMs}) {
    final (where, params, _) = _bodyPurgeWhere(sessionId, olderThanMs);
    final row = _db
        .select(
          'SELECT COUNT(*) AS n, COALESCE(SUM(size), 0) AS bytes FROM http_bodies$where',
          params,
        )
        .first;
    return {
      'rowCount': (row['n'] as int?) ?? 0,
      'totalBytes': (row['bytes'] as int?) ?? 0,
    };
  }

  (String, List<Object?>, bool) _bodyPurgeWhere(int? sessionId, int? olderThanMs) {
    final clauses = <String>[];
    final params = <Object?>[];
    if (sessionId != null) {
      clauses.add('session_id = ?');
      params.add(sessionId);
    }
    if (olderThanMs != null) {
      clauses.add('vm_id IN (SELECT vm_id FROM http_requests WHERE start_us < ?)');
      params.add(olderThanMs * 1000);
    }
    final where = clauses.isEmpty ? '' : ' WHERE ${clauses.join(' AND ')}';
    return (where, params, clauses.isNotEmpty);
  }

  /// Removes alerts matching the filters. Returns the count deleted.
  int clearAlerts({int? sessionId, String? severityMin, bool drainedOnly = false}) {
    final clauses = <String>[];
    final params = <Object?>[];
    if (sessionId != null) {
      clauses.add('session_id = ?');
      params.add(sessionId);
    }
    if (drainedOnly) clauses.add('drained = 1');
    if (severityMin != null) {
      final rank = _severityRank(severityMin);
      clauses.add(_severityRankSql('severity', '>=', rank));
    }
    final where = clauses.isEmpty ? '' : ' WHERE ${clauses.join(' AND ')}';
    final before =
        _db.select('SELECT COUNT(*) AS n FROM alerts$where', params).first['n'] as int;
    if (before == 0) return 0;
    _db.execute('DELETE FROM alerts$where', params);
    return before;
  }

  /// File + table statistics. The file size comes from `PRAGMA page_count *
  /// page_size`; SQLite has no `dbinfo()` accessible from FFI.
  Map<String, Object?> stats() {
    final tables = [
      'sessions',
      'http_requests',
      'http_bodies',
      'socket_events',
      'log_records',
      'alerts',
      'http_search_map',
      'ignored_hosts',
      'redacted_headers',
      'alert_patterns',
    ];
    final counts = <String, int>{};
    for (final t in tables) {
      try {
        counts[t] = _db.select('SELECT COUNT(*) AS n FROM $t').first['n'] as int;
      } catch (_) {
        counts[t] = -1;
      }
    }
    final pageCount = _db.select('PRAGMA page_count').first['page_count'] as int;
    final pageSize = _db.select('PRAGMA page_size').first['page_size'] as int;
    final journalMode = _db.select('PRAGMA journal_mode').first['journal_mode'];
    final fileBytes = pageCount * pageSize;
    // Bodies on-disk size: sum of size column.
    final bodiesBytes = _db
            .select('SELECT COALESCE(SUM(size),0) AS n FROM http_bodies')
            .first['n'] as int? ??
        0;
    final undrainedAlerts =
        _db.select('SELECT COUNT(*) AS n FROM alerts WHERE drained=0').first['n']
            as int;
    return {
      'rowCounts': counts,
      'sizeBytes': fileBytes,
      'sizeMb': (fileBytes / (1024 * 1024)).toStringAsFixed(2),
      'bodiesBytes': bodiesBytes,
      'bodiesMb': (bodiesBytes / (1024 * 1024)).toStringAsFixed(2),
      'pageSize': pageSize,
      'pageCount': pageCount,
      'journalMode': journalMode,
      'pendingAlerts': undrainedAlerts,
    };
  }

  void vacuum() {
    _db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    _db.execute('VACUUM');
    _db.execute('PRAGMA optimize');
  }

  // ----- redacted_headers (config) -----

  bool addRedactedHeader(String name, {String? reason}) {
    final norm = name.trim().toLowerCase();
    if (norm.isEmpty) throw ArgumentError('header name cannot be empty');
    final before = _db.select('SELECT 1 FROM redacted_headers WHERE name=?', [norm]);
    final isNew = before.isEmpty;
    _db.execute(
      'INSERT OR REPLACE INTO redacted_headers(name, added_at, reason) VALUES (?,?,?)',
      [norm, DateTime.now().millisecondsSinceEpoch, reason],
    );
    return isNew;
  }

  bool removeRedactedHeader(String name) {
    final norm = name.trim().toLowerCase();
    final before = _db.select('SELECT 1 FROM redacted_headers WHERE name=?', [norm]);
    if (before.isEmpty) return false;
    _db.execute('DELETE FROM redacted_headers WHERE name=?', [norm]);
    return true;
  }

  List<Map<String, Object?>> listRedactedHeaders() {
    final rows = _db.select(
      'SELECT name, added_at, reason FROM redacted_headers ORDER BY name',
    );
    return rows.map(_rowToMap).toList();
  }

  /// Returns the lowercase set of header names that should be redacted.
  /// Always includes the built-in defaults.
  Set<String> redactedHeaderSet() {
    final defaults = {
      'authorization',
      'cookie',
      'proxy-authorization',
      'x-api-key',
      'x-auth-token',
    };
    final extra = _db.select('SELECT name FROM redacted_headers');
    return {...defaults, ...extra.map((r) => r['name'] as String)};
  }

  // ----- alert_patterns (config) -----

  int addAlertPattern({
    required String kind,
    required String regex,
    required String severity,
    String? label,
  }) {
    if (kind.trim().isEmpty || regex.trim().isEmpty) {
      throw ArgumentError('kind and regex are required');
    }
    _severityRank(severity); // validates
    // Validate regex compiles.
    RegExp(regex, multiLine: true);
    _db.execute(
      'INSERT INTO alert_patterns(kind, regex, severity, label, added_at) VALUES (?,?,?,?,?)',
      [kind.trim(), regex, severity, label, DateTime.now().millisecondsSinceEpoch],
    );
    return _db.lastInsertRowId;
  }

  bool removeAlertPattern(int id) {
    final before = _db.select('SELECT 1 FROM alert_patterns WHERE id=?', [id]);
    if (before.isEmpty) return false;
    _db.execute('DELETE FROM alert_patterns WHERE id=?', [id]);
    return true;
  }

  List<Map<String, Object?>> listAlertPatterns() {
    final rows = _db
        .select('SELECT id, kind, regex, severity, label, added_at FROM alert_patterns ORDER BY id');
    return rows.map(_rowToMap).toList();
  }

  // ----- raw query -----

  /// Read-only SQL escape hatch. Caps row count, per-cell length, and BLOB
  /// values get summarized as `{type:'blob', size:N}` so a `SELECT * FROM
  /// http_bodies` doesn't dump megabytes back through MCP.
  List<Map<String, Object?>> rawSelect(
    String sql, {
    int rowCap = 500,
    int cellMaxChars = 2048,
  }) {
    final trimmed = sql.trim().replaceAll(RegExp(r';+\s*$'), '');
    final upper = trimmed.toUpperCase();
    if (!upper.startsWith('SELECT') && !upper.startsWith('WITH ')) {
      throw ArgumentError('Only SELECT/WITH statements are allowed.');
    }
    if (trimmed.contains(';')) {
      throw ArgumentError('Multiple statements are not allowed.');
    }
    // Wrap in a subquery so we can apply the row cap regardless of whether
    // the user already wrote their own LIMIT.
    final result = _db.select('SELECT * FROM ($trimmed) LIMIT $rowCap');
    return result.map((r) => _capRow(r, cellMaxChars)).toList();
  }

  Map<String, Object?> _capRow(sql.Row r, int cellMaxChars) {
    final out = <String, Object?>{};
    for (final k in r.keys) {
      final v = r[k];
      if (v is List<int> || v is Uint8List) {
        final len = (v as List<int>).length;
        out[k] = {'type': 'blob', 'size': len};
      } else if (v is String && v.length > cellMaxChars) {
        out[k] = {
          'value': v.substring(0, cellMaxChars),
          'truncated': true,
          'totalLength': v.length,
        };
      } else {
        out[k] = v;
      }
    }
    return out;
  }

  // ----- helpers -----

  Map<String, Object?> _rowToMap(sql.Row r) {
    return {for (final k in r.keys) k: r[k]};
  }

  String? _firstHeader(Map<String, dynamic>? headers, String name) {
    if (headers == null) return null;
    final target = name.toLowerCase();
    for (final e in headers.entries) {
      if (e.key.toLowerCase() == target) {
        final v = e.value;
        if (v is List && v.isNotEmpty) return v.first.toString();
        return v?.toString();
      }
    }
    return null;
  }
}
