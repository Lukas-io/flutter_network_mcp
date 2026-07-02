import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:test/test.dart';

/// RC2 (agent-UX audit 2026-07-02): FTS rows were written only by the body
/// backfill's has-body branch, so requests in flight at first sight (slow,
/// redirected, upgraded) or with empty bodies were NEVER indexed — ~14% of
/// historical rows. These tests pin the repair pass and the URL-first
/// indexing contract.
void main() {
  late Directory dir;
  late CapturesDao dao;
  late int sid;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('search_repair_test_');
    CapturesDatabase.open(dataDir: dir.path);
    dao = CapturesDao();
    sid = dao.createSession(
      appName: 'app',
      vmServiceUri: 'ws://x',
      isolateId: null,
      projectPath: null,
    );
  });

  tearDown(() {
    CapturesDatabase.instance.close();
    dir.deleteSync(recursive: true);
  });

  void insertReq(String vmId, String url, {String? contentType}) {
    CapturesDatabase.instance.raw.execute(
      'INSERT INTO http_requests(session_id, vm_id, url, host, path, '
      'content_type, start_us) VALUES (?,?,?,?,?,?,?)',
      [sid, vmId, url, Uri.parse(url).host, Uri.parse(url).path, contentType, 1],
    );
  }

  void insertBody(String vmId, String which, String text) {
    final bytes = Uint8List.fromList(utf8.encode(text));
    CapturesDatabase.instance.raw.execute(
      'INSERT INTO http_bodies(session_id, vm_id, which, bytes, size) '
      'VALUES (?,?,?,?,?)',
      [sid, vmId, which, bytes, bytes.length],
    );
  }

  test('repairSearchIndex indexes rows the backfill never touched', () {
    insertReq('r1', 'https://api.example.com/api/slow');
    insertReq('r2', 'https://api.example.com/api/redirect');
    expect(dao.searchIndexSize(sid), 0);

    final repaired = dao.repairSearchIndex();
    expect(repaired, 2);
    expect(dao.searchIndexSize(sid), 2);

    final hits = dao.searchRequests(sessionId: sid, query: 'slow', which: 'url');
    expect(hits, hasLength(1));
    expect(hits.first['vm_id'], 'r1');
  });

  test('repair includes stored textish bodies, skips binary', () {
    insertReq('r3', 'https://api.example.com/api/flaky',
        contentType: 'application/json');
    insertBody('r3', 'response', '{"detail":"db pool exhausted"}');
    insertReq('r4', 'https://api.example.com/api/img',
        contentType: 'image/png');
    insertBody('r4', 'response', 'PNGBYTES-not-indexed');

    dao.repairSearchIndex();

    final byBody =
        dao.searchRequests(sessionId: sid, query: 'exhausted', which: 'response');
    expect(byBody, hasLength(1));
    expect(byBody.first['vm_id'], 'r3');

    final binary =
        dao.searchRequests(sessionId: sid, query: 'PNGBYTES', which: 'response');
    expect(binary, isEmpty);
  });

  test('URL index includes the percent-decoded form (F23 i18n)', () {
    insertReq('r7', 'https://api.example.com/api/ok?coupon=%C3%9CMLAUT');
    dao.indexForSearch(
        sessionId: sid,
        vmId: 'r7',
        url: 'https://api.example.com/api/ok?coupon=%C3%9CMLAUT');
    // The human spelling matches...
    expect(
        dao.searchRequests(sessionId: sid, query: 'ÜMLAUT', which: 'url'),
        hasLength(1));
    // ...and so does the wire encoding.
    expect(
        dao.searchRequests(sessionId: sid, query: '9CMLAUT', which: 'url'),
        hasLength(1));
  });

  test('repair is idempotent', () {
    insertReq('r5', 'https://api.example.com/one-off');
    expect(dao.repairSearchIndex(), 1);
    expect(dao.repairSearchIndex(), 0);
    expect(dao.searchIndexSize(sid), 1);
  });

  test('URL-first index row is upgraded, not clobbered, by the body pass',
      () {
    insertReq('r6', 'https://api.example.com/api/orders',
        contentType: 'application/json');
    // First sight: URL-only (what the writer now does on isNew).
    dao.indexForSearch(
        sessionId: sid, vmId: 'r6', url: 'https://api.example.com/api/orders');
    expect(
        dao.searchRequests(sessionId: sid, query: 'orders', which: 'url'),
        hasLength(1));

    // Backfill arrives later with body text — must keep URL searchable.
    dao.indexForSearch(
      sessionId: sid,
      vmId: 'r6',
      url: 'https://api.example.com/api/orders',
      responseText: '{"orderId":"ord-2211"}',
    );
    expect(
        dao.searchRequests(sessionId: sid, query: 'orders', which: 'url'),
        hasLength(1));
    expect(
        dao.searchRequests(sessionId: sid, query: 'ord-2211', which: 'response'),
        hasLength(1));
    expect(dao.searchIndexSize(sid), 1, reason: 'same rowid, no duplicate');
  });
}
