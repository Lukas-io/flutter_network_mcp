import 'dart:io';

import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:test/test.dart';

/// Hardening: countRequestsForHost is parameterized, so a host/glob string
/// (now agent-supplied via ignored_hosts) can never break or inject the query.
void main() {
  late Directory dir;
  late CapturesDao dao;
  late int sid;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ignored_count_test_');
    CapturesDatabase.open(dataDir: dir.path);
    dao = CapturesDao();
    sid = dao.createSession(
        appName: 'a', vmServiceUri: 'ws://x', isolateId: null, projectPath: null);
    void req(String vmId, String host) {
      CapturesDatabase.instance.raw.execute(
        'INSERT INTO http_requests(session_id, vm_id, host) VALUES (?,?,?)',
        [sid, vmId, host],
      );
    }
    req('a', 'h.com');
    req('b', 'h.com');
    req('c', 'other.com');
  });

  tearDown(() {
    CapturesDatabase.instance.close();
    dir.deleteSync(recursive: true);
  });

  test('counts exact host, case-insensitively', () {
    expect(dao.countRequestsForHost('h.com'), 2);
    expect(dao.countRequestsForHost('H.COM'), 2);
    expect(dao.countRequestsForHost('other.com'), 1);
    expect(dao.countRequestsForHost('missing.com'), 0);
  });

  test('a glob pattern matches no literal host -> 0', () {
    expect(dao.countRequestsForHost('h.com/socket.io/*'), 0);
  });

  test('injection-shaped input is neutralized (no throw, no table drop)', () {
    final n = dao.countRequestsForHost("h.com'; DROP TABLE http_requests;--");
    expect(n, 0);
    // the table must still exist and keep its rows
    final still = CapturesDatabase.instance.raw
        .select('SELECT COUNT(*) AS n FROM http_requests')
        .first['n'];
    expect(still, 3);
  });
}
