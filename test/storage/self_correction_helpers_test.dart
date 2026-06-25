import 'dart:io';

import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:test/test.dart';

/// DAO helpers that power tool self-correction: schemaDigest (network_query
/// error), distinctHosts + searchIndexSize (network_search empty).
void main() {
  late Directory dir;
  late CapturesDao dao;
  late int sid;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('self_correct_test_');
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

  void insertReq(String vmId, String host) {
    CapturesDatabase.instance.raw.execute(
      'INSERT INTO http_requests(session_id, vm_id, host, start_us) '
      'VALUES (?,?,?,?)',
      [sid, vmId, host, 100],
    );
  }

  test('schemaDigest lists user tables with their columns, hides internals', () {
    final schema = dao.schemaDigest();
    expect(schema.keys, contains('http_requests'));
    expect(schema.keys, contains('sessions'));
    expect(schema['http_requests'], contains('host'));
    expect(schema['http_requests'], contains('session_id'));
    // sqlite internals + FTS shadow tables must not leak.
    expect(schema.keys.any((k) => k.startsWith('sqlite_')), isFalse);
    expect(schema.keys.any((k) => k.contains('_fts') || k == 'http_search'),
        isFalse);
  });

  test('distinctHosts returns captured hosts busiest-first', () {
    insertReq('a', 'api.example.com');
    insertReq('b', 'api.example.com');
    insertReq('c', 'cdn.example.com');
    final hosts = dao.distinctHosts(sid);
    expect(hosts.first, 'api.example.com'); // 2 beats 1
    expect(hosts, containsAll(['api.example.com', 'cdn.example.com']));
  });

  test('searchIndexSize is 0 before backfill, distinguishing empty causes', () {
    insertReq('a', 'api.example.com');
    // No http_search_map rows inserted -> nothing indexed yet.
    expect(dao.searchIndexSize(sid), 0);
  });
}
