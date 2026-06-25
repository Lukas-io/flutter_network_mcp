import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_mcp/server.dart';
import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/tools/network_drift.dart';
import 'package:test/test.dart';

/// 0.9.6: drift detection samples BOTH ends of the timeline, so the oldest
/// (pre-drift) shape is compared even when the matched set exceeds the sample
/// cap on a high-volume session.
void main() {
  late Directory dir;
  late CapturesDao dao;
  late int sid;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('drift_window_');
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

  void profileReq(String vmId, int startUs, Map<String, Object?> body) {
    CapturesDatabase.instance.raw.execute(
      'INSERT INTO http_requests(session_id, vm_id, method, url, host, path, '
      'status_code, content_type, start_us) VALUES (?,?,?,?,?,?,?,?,?)',
      [sid, vmId, 'GET', 'https://api.x/profile', 'api.x', '/profile', 200,
        'application/json', startUs],
    );
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(body)));
    CapturesDatabase.instance.raw.execute(
      'INSERT INTO http_bodies(session_id, vm_id, which, bytes, size) '
      'VALUES (?,?,?,?,?)',
      [sid, vmId, 'response', bytes, bytes.length],
    );
  }

  test('oldest shape still compared when matched set exceeds sample cap', () async {
    // 12 responses: the OLDEST (start 0) has the small shape; the rest gained
    // an `email` field. With limit:4, naive newest-only sampling would miss
    // the oldest and report no drift.
    profileReq('v0', 0, {'id': 1, 'name': 'a'});
    for (var i = 1; i < 12; i++) {
      profileReq('v$i', i * 1000, {'id': 1, 'name': 'a', 'email': 'x'});
    }
    final res = await networkDrift(CallToolRequest(
      name: 'network_drift',
      arguments: {'sessionId': sid, 'pathContains': 'profile', 'limit': 4},
    ));
    expect(res.isError, isFalse);
    final sc = res.structuredContent!;
    expect(sc['drifted'], isTrue, reason: 'added=${sc['added']}');
    expect((sc['added'] as List), contains('email'));
    expect(sc['matchedTotal'], 12);
  });

  test('stable contract across many responses -> no drift', () async {
    for (var i = 0; i < 8; i++) {
      profileReq('v$i', i * 1000, {'id': 1, 'name': 'a'});
    }
    final res = await networkDrift(CallToolRequest(
      name: 'network_drift',
      arguments: {'sessionId': sid, 'pathContains': 'profile', 'limit': 4},
    ));
    expect(res.structuredContent!['drifted'], isFalse);
  });
}
