import 'dart:convert';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart' as sql;

import '../config/body_decryption.dart';
import '../util/searchable_text.dart';
import 'captures_db.dart';
import 'database.dart';
import '../util/body_decoder.dart';

/// Search over decrypted bodies (#105), held in this process's memory only so plaintext never reaches the capture DB. Built per session on first search and topped up on later ones; dropped when the key changes or decryption is turned off.
class PlaintextIndex {
  PlaintextIndex._();
  static final instance = PlaintextIndex._();

  sql.Database? _db;

  /// Per session, the requests already indexed; true once their bodies were final, so they need no second look.
  final Map<int, Map<String, bool>> _indexed = {};

  sql.Database get _mem => _db ??= _open();

  static sql.Database _open() {
    final db = sql.sqlite3.openInMemory();
    db.execute('CREATE VIRTUAL TABLE plain_search USING fts5('
        "url, content_request, content_response, tokenize='unicode61')");
    db.execute('CREATE TABLE plain_map (rowid INTEGER PRIMARY KEY, '
        'session_id INTEGER NOT NULL, vm_id TEXT NOT NULL, isolate_id TEXT, '
        'start_us INTEGER, UNIQUE(session_id, vm_id))');
    return db;
  }

  /// Forgets everything; the next search rebuilds with the current key.
  void clear() {
    _db?.dispose();
    _db = null;
    _indexed.clear();
  }

  /// Drops [sessionId]'s rows, after its bodies or the session itself left the capture DB; the next search re-reads what is left.
  void forget(int sessionId) {
    if (_indexed.remove(sessionId) == null) return;
    final db = _db;
    if (db == null) return;
    db.execute('DELETE FROM plain_search WHERE rowid IN '
        '(SELECT rowid FROM plain_map WHERE session_id=?)', [sessionId]);
    db.execute('DELETE FROM plain_map WHERE session_id=?', [sessionId]);
  }

  /// Sessions indexed so far.
  Set<int> get sessions => _indexed.keys.toSet();

  /// Requests of [sessionId] held in the index.
  int indexedCount(int sessionId) => _indexed[sessionId]?.length ?? 0;

  /// Indexes [sessionId]'s requests not seen yet and re-reads those whose bodies were still arriving. Returns how many were (re)indexed.
  int refresh(int sessionId, BodyDecryption scheme) {
    final raw = CapturesDatabase.instance.raw;
    final seen = _indexed.putIfAbsent(sessionId, () => {});
    var n = 0;
    for (final row in raw.select(
      'SELECT vm_id, isolate_id, url, content_type, request_headers_json, '
      'response_headers_json, start_us, bodies_fetched '
      'FROM http_requests WHERE session_id=?',
      [sessionId],
    )) {
      final vmId = row['vm_id'] as String;
      if (seen[vmId] == true) continue;
      String? request;
      String? response;
      for (final b in raw.select(
        'SELECT which, bytes FROM http_bodies WHERE session_id=? AND vm_id=?',
        [sessionId, vmId],
      )) {
        final text = plaintextFor(b['bytes'] as Uint8List?,
            storedContentType(_row(row), b['which'] as String), scheme);
        if (b['which'] == 'request') {
          request = text;
        } else {
          response = text;
        }
      }
      _put(
        sessionId: sessionId,
        vmId: vmId,
        isolateId: row['isolate_id'] as String?,
        startUs: row['start_us'] as int?,
        url: (row['url'] as String?) ?? '',
        request: request,
        response: response,
      );
      seen[vmId] = (row['bodies_fetched'] as int? ?? 0) != 0;
      n++;
    }
    return n;
  }

  void _put({
    required int sessionId,
    required String vmId,
    required String? isolateId,
    required int? startUs,
    required String url,
    required String? request,
    required String? response,
  }) {
    final db = _mem;
    final existing = db.select(
        'SELECT rowid FROM plain_map WHERE session_id=? AND vm_id=?',
        [sessionId, vmId]);
    if (existing.isNotEmpty) {
      db.execute('DELETE FROM plain_search WHERE rowid=?',
          [existing.first['rowid']]);
      db.execute('DELETE FROM plain_map WHERE rowid=?', [existing.first['rowid']]);
    }
    db.execute(
      'INSERT INTO plain_map(session_id, vm_id, isolate_id, start_us) VALUES (?,?,?,?)',
      [sessionId, vmId, isolateId, startUs],
    );
    db.execute(
      'INSERT INTO plain_search(rowid, url, content_request, content_response) '
      'VALUES (?,?,?,?)',
      [db.lastInsertRowId, CapturesDao.urlForIndex(url), request ?? '', response ?? ''],
    );
  }

  /// The same rows [CapturesDao.searchRequests] returns, ranked by BM25 over plaintext.
  List<Map<String, Object?>> search({
    required String query,
    required int sessionId,
    String which = 'any',
    String? isolateId,
    int limit = 20,
  }) =>
      _query(
        CapturesDao.ftsMatchExpr(query, which),
        sessionId,
        isolateId: isolateId,
        orderBy: 'rank',
        limit: limit,
      );

  /// The same rows [CapturesDao.correlateAcrossSessions] returns for one session, oldest first.
  List<Map<String, Object?>> correlate({
    required String pattern,
    required int sessionId,
    String which = 'any',
    int limit = 100,
  }) =>
      _query(
        CapturesDao.ftsMatchExpr(pattern, which),
        sessionId,
        orderBy: 'm.start_us ASC',
        limit: limit,
      );

  List<Map<String, Object?>> _query(String matchExpr, int sessionId,
      {String? isolateId, required String orderBy, required int limit}) {
    final hasIsolate = isolateId != null && isolateId.isNotEmpty;
    final hits = _mem.select(
      '''
      SELECT m.session_id AS session_id, m.vm_id AS vm_id,
        m.isolate_id AS isolate_id,
        snippet(plain_search, -1, '«', '»', '…', 12) AS snippet,
        bm25(plain_search) AS rank
      FROM plain_search JOIN plain_map m ON m.rowid = plain_search.rowid
      WHERE plain_search MATCH ? AND m.session_id = ?
        ${hasIsolate ? 'AND m.isolate_id = ?' : ''}
      ORDER BY $orderBy LIMIT ?
      ''',
      [matchExpr, sessionId, if (hasIsolate) isolateId, limit],
    );
    final meta = CapturesDao()
        .requestSummaries(sessionId, [for (final h in hits) h['vm_id'] as String]);
    return [
      for (final h in hits)
        {
          ...?meta[h['vm_id']],
          'session_id': h['session_id'],
          'vm_id': h['vm_id'],
          'isolate_id': h['isolate_id'],
          'snippet': h['snippet'],
          'rank': h['rank'],
        },
    ];
  }
}

/// A body's searchable text for the in-memory index: its plaintext when it decrypts under [scheme], else what the capture DB would index.
String? plaintextFor(Uint8List? bytes, String? contentType, BodyDecryption scheme) {
  if (bytes == null || bytes.isEmpty) return null;
  final out = scheme.decrypt(bytes);
  if (out.decrypted) return utf8.decode(out.bytes);
  return searchableText(bytes, contentType);
}

Map<String, Object?> _row(sql.Row r) => {for (final k in r.keys) k: r[k]};
