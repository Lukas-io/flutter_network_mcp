import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/tools/network_report.dart';
import 'package:test/test.dart';

/// 0.9.5: one-call session health triage.
void main() {
  late Directory dir;
  late CapturesDao dao;
  late int sid;
  var vm = 0;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('report_test_');
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

  void req(String method, String host, String path, int status, int durMs) {
    CapturesDatabase.instance.raw.execute(
      'INSERT INTO http_requests(session_id, vm_id, method, url, host, path, '
      'status_code, start_us, duration_us) VALUES (?,?,?,?,?,?,?,?,?)',
      [sid, 'v${vm++}', method, 'https://$host$path', host, path, status, 1000,
        durMs * 1000],
    );
  }

  test('surfaces the worst error endpoint as the headline', () async {
    for (var i = 0; i < 5; i++) {
      req('POST', 'api.x', '/login', 500, 50);
    }
    for (var i = 0; i < 4; i++) {
      req('GET', 'api.x', '/ping', 200, 10);
    }
    final res = await networkReport(CallToolRequest(
      name: 'network_report',
      arguments: {'sessionId': sid},
    ));
    expect(res.isError, isFalse);
    final sc = res.structuredContent!;
    expect(sc['summary'].toString(), contains('/login'));
    expect(sc['summary'].toString(), contains('100%'));
    expect(sc['totalRequests'], 9);
    final hotspots = (sc['errorHotspots'] as List).cast<Map<String, Object?>>();
    expect(hotspots.first['endpoint'].toString(), contains('/login'));
    expect((sc['nextSteps'] as List).join(' '), contains('network_drift'));
  });

  test('healthy session reports healthy', () async {
    for (var i = 0; i < 4; i++) {
      req('GET', 'api.x', '/ping', 200, 10);
    }
    final res = await networkReport(CallToolRequest(
      name: 'network_report',
      arguments: {'sessionId': sid},
    ));
    final sc = res.structuredContent!;
    expect(sc['summary'].toString().toLowerCase(), contains('healthy'));
    expect(sc['errorHotspots'], isEmpty);
  });

  test('empty session is reported, not errored', () async {
    final res = await networkReport(CallToolRequest(
      name: 'network_report',
      arguments: {'sessionId': sid},
    ));
    expect(res.isError, isFalse);
    expect(res.structuredContent!['summary'].toString(), contains('No HTTP'));
  });
}
