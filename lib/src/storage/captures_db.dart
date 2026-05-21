import 'dart:convert';
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

  List<Map<String, Object?>> listSessions({
    String? projectPath,
    int? sinceMs,
    int limit = 20,
  }) {
    final clauses = <String>[];
    final params = <Object?>[];
    if (projectPath != null) {
      clauses.add('project_path = ?');
      params.add(projectPath);
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

  // ----- http -----

  /// Upserts a request summary. Returns true if a new row was inserted.
  bool upsertHttpRequest(int sessionId, HttpProfileRequest r) {
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
      'INSERT INTO http_requests(session_id, vm_id, method, url, host, path, status_code, reason_phrase, start_us, end_us, duration_us, request_size, response_size, content_type, request_headers_json, response_headers_json, has_error) '
      'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) '
      'ON CONFLICT(session_id, vm_id) DO UPDATE SET '
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

  /// Returns ids of requests in the session that are complete but have no bodies stored yet.
  List<String> pendingBodyFetches(int sessionId, {int limit = 50}) {
    final rows = _db.select(
      'SELECT vm_id FROM http_requests WHERE session_id=? AND bodies_fetched=0 AND end_us IS NOT NULL ORDER BY end_us ASC LIMIT ?',
      [sessionId, limit],
    );
    return rows.map((r) => r['vm_id'] as String).toList();
  }

  List<Map<String, Object?>> queryHttpRequests({
    required int sessionId,
    int? sinceUs,
    List<String>? methods,
    String? hostContains,
    int? statusMin,
    int? statusMax,
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

  void upsertSocket(int sessionId, SocketStatistic s) {
    _db.execute(
      'INSERT INTO socket_events(session_id, vm_id, socket_type, address, port, start_us, end_us, last_read_us, last_write_us, read_bytes, write_bytes) '
      'VALUES (?,?,?,?,?,?,?,?,?,?,?) '
      'ON CONFLICT(session_id, vm_id) DO UPDATE SET '
      '  end_us=excluded.end_us, last_read_us=excluded.last_read_us, last_write_us=excluded.last_write_us, '
      '  read_bytes=excluded.read_bytes, write_bytes=excluded.write_bytes',
      [
        sessionId,
        s.id,
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
    int limit = 50,
  }) {
    final rows = _db.select(
      'SELECT * FROM socket_events WHERE session_id=? ORDER BY start_us DESC LIMIT ?',
      [sessionId, limit],
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
  }) {
    _db.execute(
      'INSERT INTO log_records(session_id, timestamp_ms, source, level, logger, message, error, stack_trace) VALUES (?,?,?,?,?,?,?,?)',
      [sessionId, timestampMs, source, level, logger, message, error, stackTrace],
    );
    return _db.lastInsertRowId;
  }

  List<Map<String, Object?>> queryLogs({
    required int sessionId,
    int? sinceId,
    int? levelMin,
    String? loggerContains,
    String? source,
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
    if (source != null && source.isNotEmpty) {
      clauses.add('source = ?');
      params.add(source);
    }
    final rows = _db.select(
      'SELECT * FROM log_records WHERE ${clauses.join(' AND ')} ORDER BY id DESC LIMIT ?',
      [...params, limit],
    );
    return rows.map(_rowToMap).toList();
  }

  // ----- alerts -----

  /// Inserts an alert if one with the same (session_id, kind, source_id)
  /// doesn't already exist. Returns true when a new row was inserted.
  bool insertAlert({
    required int sessionId,
    required String severity,
    required String kind,
    required String title,
    String? detail,
    String? sourceKind,
    String? sourceId,
    int? tsMs,
  }) {
    final ts = tsMs ?? DateTime.now().millisecondsSinceEpoch;
    final before = _db.select(
      'SELECT id FROM alerts WHERE session_id=? AND kind=? AND source_id IS ?',
      [sessionId, kind, sourceId],
    );
    if (before.isNotEmpty) return false;
    _db.execute(
      'INSERT INTO alerts(session_id, ts_ms, severity, kind, title, detail, source_kind, source_id) '
      'VALUES (?,?,?,?,?,?,?,?)',
      [sessionId, ts, severity, kind, title, detail, sourceKind, sourceId],
    );
    return true;
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
      return;
    }
    _db.execute(
      'INSERT INTO http_search(url, content_request, content_response) VALUES (?,?,?)',
      [url, requestText ?? '', responseText ?? ''],
    );
    final rowid = _db.lastInsertRowId;
    _db.execute(
      'INSERT INTO http_search_map(rowid, session_id, vm_id) VALUES (?,?,?)',
      [rowid, sessionId, vmId],
    );
  }

  List<Map<String, Object?>> searchRequests({
    required String query,
    int? sessionId,
    String which = 'any',
    int limit = 20,
  }) {
    // Restrict to a specific column by prepending the FTS5 column-filter
    // syntax `colname:` to the user query in Dart, so the SQL itself stays
    // parameterized with a single placeholder.
    final String matchExpr;
    switch (which) {
      case 'request':
        matchExpr = 'content_request:$query';
        break;
      case 'response':
        matchExpr = 'content_response:$query';
        break;
      case 'url':
        matchExpr = 'url:$query';
        break;
      case 'any':
      default:
        matchExpr = query;
    }
    const matchClause = 'http_search MATCH ?';
    final params = <Object?>[matchExpr];
    String sessionFilter = '';
    if (sessionId != null) {
      sessionFilter = ' AND m.session_id = ?';
      params.add(sessionId);
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
      WHERE $matchClause$sessionFilter
      ORDER BY rank LIMIT ?
      ''',
      params,
    );
    return rows.map(_rowToMap).toList();
  }

  // ----- raw query -----

  List<Map<String, Object?>> rawSelect(String sql, {int rowCap = 500}) {
    final trimmed = sql.trim().replaceAll(RegExp(r';+\s*$'), '');
    final upper = trimmed.toUpperCase();
    if (!upper.startsWith('SELECT') && !upper.startsWith('WITH ')) {
      throw ArgumentError('Only SELECT/WITH statements are allowed.');
    }
    if (trimmed.contains(';')) {
      throw ArgumentError('Multiple statements are not allowed.');
    }
    final result = _db.select('$trimmed LIMIT $rowCap');
    return result.map(_rowToMap).toList();
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
