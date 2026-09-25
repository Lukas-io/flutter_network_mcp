import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_network_mcp/src/config/body_decryption.dart';
import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/storage/plaintext_index.dart';
import 'package:flutter_network_mcp/src/util/searchable_text.dart';
import 'package:test/test.dart';

const _key = '0123456789abcdef0123456789abcdef';
const _iv = '000102030405060708090a0b0c0d0e0f';

/// openssl enc -aes-256-ctr of {"status":"ok","account":"Adaeze Okafor","balance":1520.75}, hex.
const _cipher =
    '287faf81f7bb43172306a522eeab97032733b02277497f77066482b40ffc872b8c543a7b29bd8d50c0dac76bc3223817d3d6aa7c77523faf7b9741';
final _body = Uint8List.fromList(utf8.encode('$_iv$_cipher'));

/// #105 follow-up: decrypted text is searchable but never reaches the capture DB.
void main() {
  late Directory dir;
  late CapturesDao dao;
  late int sid;
  late BodyDecryption scheme;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('plaintext_index_test_');
    CapturesDatabase.open(dataDir: dir.path);
    dao = CapturesDao();
    sid = dao.createSession(
        appName: 'bank', vmServiceUri: 'ws://x', isolateId: null, projectPath: null);
    scheme = BodyDecryption.parse({'key': _key, 'ivMode': 'prefix'}).config!;
    PlaintextIndex.instance.clear();
  });
  tearDown(() {
    PlaintextIndex.instance.clear();
    CapturesDatabase.instance.close();
    dir.deleteSync(recursive: true);
  });

  void storeBody(String vmId) {
    CapturesDatabase.instance.raw.execute(
      'INSERT INTO http_bodies(session_id, vm_id, which, bytes, size) VALUES (?,?,?,?,?)',
      [sid, vmId, 'response', _body, _body.length],
    );
    dao.indexForSearch(
        sessionId: sid, vmId: vmId, url: 'http://api.test/balance',
        responseText: searchableText(_body, 'text/plain'));
  }

  void request(String vmId, {bool withBody = true, int fetched = 1}) {
    final raw = CapturesDatabase.instance.raw;
    raw.execute(
      'INSERT INTO http_requests(session_id, vm_id, method, url, content_type, '
      'start_us, bodies_fetched) VALUES (?,?,?,?,?,?,?)',
      [sid, vmId, 'POST', 'http://api.test/balance', 'text/plain', 100, fetched],
    );
    if (withBody) storeBody(vmId);
  }

  test('plaintext is searchable in memory, with the capture DB\'s row shape', () {
    request('r1');
    PlaintextIndex.instance.refresh(sid, scheme);
    final hits = PlaintextIndex.instance.search(query: 'Adaeze', sessionId: sid);
    expect(hits, hasLength(1));
    expect(hits.single['vm_id'], 'r1');
    expect(hits.single['method'], 'POST');
    expect(hits.single['snippet'], contains('«Adaeze»'));
  });

  test('the capture DB index and file never hold the plaintext', () {
    BodyDecryptionConfig.active = scheme;
    addTearDown(() => BodyDecryptionConfig.active = null);
    request('r1');
    PlaintextIndex.instance.refresh(sid, scheme);
    expect(dao.searchRequests(query: 'Adaeze', sessionId: sid), isEmpty);
    CapturesDatabase.instance.raw.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    final file = File('${dir.path}/captures.db').readAsBytesSync();
    expect(latin1.decode(file).contains('Adaeze'), isFalse);
  });

  test('a body stored after the first search is picked up on the next', () {
    request('r2', withBody: false, fetched: 0);
    PlaintextIndex.instance.refresh(sid, scheme);
    expect(PlaintextIndex.instance.search(query: 'Adaeze', sessionId: sid), isEmpty);
    storeBody('r2');
    PlaintextIndex.instance.refresh(sid, scheme);
    expect(PlaintextIndex.instance.search(query: 'Adaeze', sessionId: sid), hasLength(1));
  });

  test('clear drops every plaintext row', () {
    request('r1');
    PlaintextIndex.instance.refresh(sid, scheme);
    PlaintextIndex.instance.clear();
    expect(PlaintextIndex.instance.sessions, isEmpty);
    expect(PlaintextIndex.instance.search(query: 'Adaeze', sessionId: sid), isEmpty);
  });

  test('forget drops one session and keeps the others', () {
    request('r1');
    final other = dao.createSession(
        appName: 'bank2', vmServiceUri: 'ws://y', isolateId: null, projectPath: null);
    final keep = sid;
    sid = other;
    request('r1');
    PlaintextIndex.instance.refresh(keep, scheme);
    PlaintextIndex.instance.refresh(other, scheme);

    PlaintextIndex.instance.forget(other);
    expect(PlaintextIndex.instance.sessions, {keep});
    expect(PlaintextIndex.instance.indexedCount(other), 0);
    expect(PlaintextIndex.instance.search(query: 'Adaeze', sessionId: other), isEmpty);
    expect(PlaintextIndex.instance.search(query: 'Adaeze', sessionId: keep), hasLength(1));
  });

  test('correlate returns the plaintext match oldest first', () {
    request('r1');
    PlaintextIndex.instance.refresh(sid, scheme);
    final rows = PlaintextIndex.instance.correlate(pattern: 'Okafor', sessionId: sid);
    expect(rows.single['url'], 'http://api.test/balance');
  });
}
