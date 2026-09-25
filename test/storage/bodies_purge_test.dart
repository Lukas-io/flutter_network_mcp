import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_mcp/server.dart';
import 'package:flutter_network_mcp/src/config/body_decryption.dart';
import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/storage/plaintext_index.dart';
import 'package:flutter_network_mcp/src/tools/bodies_purge.dart';
import 'package:flutter_network_mcp/src/tools/network_search.dart';
import 'package:flutter_network_mcp/src/tools/session_delete.dart';
import 'package:test/test.dart';

const _key = '0123456789abcdef0123456789abcdef';
const _iv = '000102030405060708090a0b0c0d0e0f';

/// openssl enc -aes-256-ctr of {"status":"ok","account":"Adaeze Okafor","balance":1520.75}, hex.
const _cipher =
    '287faf81f7bb43172306a522eeab97032733b02277497f77066482b40ffc872b8c543a7b29bd8d50c0dac76bc3223817d3d6aa7c77523faf7b9741';

/// bodies_purge, session_delete and network_search keep both search indexes in step with the bodies actually stored.
void main() {
  late Directory dir;
  late CapturesDao dao;
  late int old;
  late int recent;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('bodies_purge_test_');
    CapturesDatabase.open(dataDir: dir.path);
    dao = CapturesDao();
    old = dao.createSession(
        appName: 'a', vmServiceUri: 'ws://old', isolateId: null, projectPath: null);
    dao.endSession(old);
    recent = dao.createSession(
        appName: 'a', vmServiceUri: 'ws://new', isolateId: null, projectPath: null);
    dao.endSession(recent);
    PlaintextIndex.instance.clear();
  });
  tearDown(() {
    BodyDecryptionConfig.active = null;
    PlaintextIndex.instance.clear();
    CapturesDatabase.instance.close();
    dir.deleteSync(recursive: true);
  });

  void capture(int sid, String vmId, int startUs, String body, {bool index = true}) {
    final raw = CapturesDatabase.instance.raw;
    raw.execute(
      'INSERT INTO http_requests(session_id, vm_id, method, url, content_type, '
      'start_us, end_us, bodies_fetched) VALUES (?,?,?,?,?,?,?,1)',
      [sid, vmId, 'GET', 'http://api.test/$vmId', 'text/plain', startUs, startUs + 1],
    );
    final bytes = Uint8List.fromList(utf8.encode(body));
    raw.execute(
      'INSERT INTO http_bodies(session_id, vm_id, which, bytes, size) VALUES (?,?,?,?,?)',
      [sid, vmId, 'response', bytes, bytes.length],
    );
    if (index) {
      dao.indexForSearch(
          sessionId: sid, vmId: vmId, url: 'http://api.test/$vmId', responseText: body);
    }
  }

  int bodies(int sid) => CapturesDatabase.instance.raw
      .select('SELECT COUNT(*) AS n FROM http_bodies WHERE session_id=?', [sid])
      .first['n'] as int;

  int fetched(int sid) => CapturesDatabase.instance.raw
      .select('SELECT SUM(bodies_fetched) AS n FROM http_requests WHERE session_id=?', [sid])
      .first['n'] as int;

  Future<Map<String, Object?>> call(FutureOr<CallToolResult> Function(CallToolRequest) tool,
          String name, Map<String, Object?> args) async =>
      (await tool(CallToolRequest(name: name, arguments: args))).structuredContent!;

  test('olderThanMs matches requests of the same session only', () async {
    capture(old, 'r1', 1000, 'old body');
    capture(recent, 'r1', 9000000, 'new body');

    final dry = await call(bodiesPurge, 'bodies_purge', {'olderThanMs': 5});
    expect(dry['wouldPurgeRows'], 1);
    final res = await call(bodiesPurge, 'bodies_purge', {'olderThanMs': 5, 'confirm': true});
    expect(res['purgedBodies'], 1);
    expect(res['purgedSessions'], [old]);
    expect(bodies(old), 0);
    expect(bodies(recent), 1, reason: 'a newer body sharing the request id stays');
  });

  test('only the purged requests go back to unfetched', () async {
    capture(old, 'r1', 1000, 'a');
    capture(old, 'r2', 9000000, 'b');
    capture(recent, 'r3', 1000, 'c');

    await call(bodiesPurge, 'bodies_purge', {'sessionId': old, 'olderThanMs': 5, 'confirm': true});
    expect(fetched(old), 1, reason: 'r2 was not purged');
    expect(fetched(recent), 1, reason: 'another session is untouched');
  });

  test('purged body text leaves the search index, the URL stays', () async {
    capture(old, 'r1', 1000, 'needle in the body');
    expect(dao.searchRequests(query: 'needle', sessionId: old), hasLength(1));

    await call(bodiesPurge, 'bodies_purge', {'sessionId': old, 'confirm': true});
    expect(dao.searchRequests(query: 'needle', sessionId: old), isEmpty);
    expect(dao.searchRequests(query: 'api.test/r1', sessionId: old, which: 'url'), hasLength(1));
  });

  group('with body decryption on', () {
    setUp(() {
      BodyDecryptionConfig.active =
          BodyDecryption.parse({'key': _key, 'ivMode': 'prefix'}).config;
    });

    Future<List<Object?>> search(int sid) async =>
        (await call(networkSearch, 'network_search', {'query': 'Adaeze', 'sessionId': sid}))['matches']
            as List<Object?>;

    test('a purge drops the decrypted text held in memory', () async {
      capture(old, 'r1', 1000, '$_iv$_cipher', index: false);
      expect(await search(old), hasLength(1));

      await call(bodiesPurge, 'bodies_purge', {'sessionId': old, 'confirm': true});
      expect(await search(old), isEmpty);
    });

    test('a deleted session no longer matches in memory', () async {
      capture(old, 'r1', 1000, '$_iv$_cipher', index: false);
      expect(await search(old), hasLength(1));

      await call(sessionDelete, 'session_delete', {'id': old, 'confirm': true});
      expect(PlaintextIndex.instance.sessions, isNot(contains(old)));
      expect(PlaintextIndex.instance.search(query: 'Adaeze', sessionId: old), isEmpty);
    });

    test('zero-match warnings describe the in-memory index that was searched', () async {
      capture(old, 'r1', 1000, '$_iv$_cipher', index: false);
      final sc = await call(networkSearch, 'network_search', {'query': 'absent', 'sessionId': old});
      expect(sc['index'], 'decrypted-in-memory');
      final warnings = (sc['warnings'] as List).join(' ');
      expect(warnings, contains('in-memory decrypted index'));
      expect(warnings, isNot(contains('Nothing is indexed')));
    });
  });
}
