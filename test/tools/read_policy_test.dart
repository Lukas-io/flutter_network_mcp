import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/tools/network_correlate.dart';
import 'package:flutter_network_mcp/src/tools/network_list.dart';
import 'package:flutter_network_mcp/src/tools/network_summarize.dart';
import 'package:test/test.dart';

/// PR B (audit RC5/RC7/F24): history-aware cursors, whole-session windows,
/// and bounded correlate payloads.
void main() {
  late Directory dir;
  late CapturesDao dao;
  late int sid;
  var vm = 0;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('read_policy_test_');
    CapturesDatabase.open(dataDir: dir.path);
    dao = CapturesDao();
    sid = dao.createSession(
        appName: 'a', vmServiceUri: 'ws://x', isolateId: null, projectPath: null);
  });

  tearDown(() {
    CapturesDatabase.instance.close();
    dir.deleteSync(recursive: true);
  });

  void req(int startUs, {String host = 'api.x', int status = 200}) {
    CapturesDatabase.instance.raw.execute(
      'INSERT INTO http_requests(session_id, vm_id, method, url, host, path, '
      'status_code, start_us, duration_us) VALUES (?,?,?,?,?,?,?,?,?)',
      [sid, 'v${vm++}', 'GET', 'https://$host/p$vm', host, '/p$vm', status,
        startUs, 1000],
    );
  }

  test('history network_list before: pages older; nextCursor feeds it',
      () async {
    for (var i = 0; i < 10; i++) {
      req(1000 + i * 1000);
    }
    dao.endSession(sid); // history session

    final page1 = await networkList(CallToolRequest(
        name: 'network_list', arguments: {'sessionId': sid, 'limit': 4}));
    final sc1 = page1.structuredContent!;
    expect((sc1['requests'] as List), hasLength(4));
    final cursor = sc1['nextCursor'] as int?;
    expect(cursor, isNotNull, reason: 'a full page should offer an older cursor');
    expect((sc1['nextSteps'] as List).join(), contains('before:'));

    final page2 = await networkList(CallToolRequest(
        name: 'network_list',
        arguments: {'sessionId': sid, 'limit': 4, 'before': cursor}));
    final rows2 = (page2.structuredContent!['requests'] as List)
        .cast<Map<String, Object?>>();
    expect(rows2, isNotEmpty);
    // Every row in page 2 is strictly older than the page-1 cursor.
    for (final r in rows2) {
      expect(r['startTimeMs'] as int, lessThan(cursor! ~/ 1000 + 1));
    }
  });

  test('history network_list no longer suggests the dead since:<newest> hint',
      () async {
    for (var i = 0; i < 3; i++) {
      req(1000 + i * 1000);
    }
    dao.endSession(sid);
    final res = await networkList(CallToolRequest(
        name: 'network_list', arguments: {'sessionId': sid}));
    final steps = (res.structuredContent!['nextSteps'] as List).join(' ');
    expect(steps, isNot(contains('page beyond the newest')));
  });

  test('summarize on an ended session defaults to the whole session', () async {
    // A request 2 days ago — outside any 1h window.
    final oldUs = DateTime.now()
            .subtract(const Duration(days: 2))
            .microsecondsSinceEpoch;
    req(oldUs);
    dao.endSession(sid);

    final res = await networkSummarize(CallToolRequest(
        name: 'network_summarize', arguments: {'sessionId': sid}));
    final sc = res.structuredContent!;
    expect(sc['summary'].toString(), contains('entire session'));
    expect((sc['endpoints'] as List), isNotEmpty,
        reason: 'the 2-day-old request must be counted, not windowed out');
  });

  test('correlate previews first 10 matches, not the full dump', () async {
    // 25 matching rows in one session — the flood case.
    for (var i = 0; i < 25; i++) {
      CapturesDatabase.instance.raw.execute(
        'INSERT INTO http_requests(session_id, vm_id, method, url, host, '
        'path, status_code, start_us) VALUES (?,?,?,?,?,?,?,?)',
        [sid, 'c$i', 'GET', 'https://api.x/trace-ABC', 'api.x', '/trace-ABC',
          200, 1000 + i],
      );
      dao.indexForSearch(
          sessionId: sid, vmId: 'c$i', url: 'https://api.x/trace-ABC');
    }
    final res = await networkCorrelate(CallToolRequest(
        name: 'network_correlate',
        arguments: {'sessionIds': [sid], 'pattern': 'trace-ABC'}));
    final session0 = (res.structuredContent!['sessions'] as List).first
        as Map<String, Object?>;
    expect(session0['matchesTotal'], 25);
    expect(session0['matchesShown'], 10);
    expect((session0['matches'] as List), hasLength(10));
    // Compact form: no snippet in the sessions[] preview.
    expect((session0['matches'] as List).first, isNot(contains('snippet')));
  });
}
