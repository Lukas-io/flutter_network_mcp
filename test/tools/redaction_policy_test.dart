import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/tools/network_diff.dart';
import 'package:flutter_network_mcp/src/tools/network_get.dart';
import 'package:flutter_network_mcp/src/tools/network_replay.dart';
import 'package:flutter_network_mcp/src/tools/session_export.dart';
import 'package:test/test.dart';

/// D5 (audit RC9/F7): redaction is a serialization-layer policy. A secret
/// auth header must never appear in get/diff/replay output, or in a HAR
/// export, unless the caller explicitly opts out.
void main() {
  late Directory dir;
  late CapturesDao dao;
  late int sid;

  const secret = 'Bearer SUPER-SECRET-TOKEN-123';

  setUp(() {
    dir = Directory.systemTemp.createTempSync('redaction_test_');
    CapturesDatabase.open(dataDir: dir.path);
    dao = CapturesDao();
    sid = dao.createSession(
        appName: 'a', vmServiceUri: 'ws://x', isolateId: null, projectPath: null);
    void insert(String vmId, int status) {
      CapturesDatabase.instance.raw.execute(
        'INSERT INTO http_requests(session_id, vm_id, method, url, host, path, '
        'status_code, start_us, request_headers_json, response_headers_json) '
        'VALUES (?,?,?,?,?,?,?,?,?,?)',
        [sid, vmId, 'GET', 'https://api.x/a', 'api.x', '/a', status, 1000,
          jsonEncode({'authorization': secret, 'accept': 'application/json'}),
          jsonEncode({'content-type': 'application/json'})],
      );
    }
    insert('r1', 200);
    insert('r2', 401);
  });

  tearDown(() {
    CapturesDatabase.instance.close();
    dir.deleteSync(recursive: true);
  });

  test('network_get redacts auth headers by default', () async {
    final res = await networkGet(CallToolRequest(
        name: 'network_get', arguments: {'sessionId': sid, 'id': 'r1'}));
    final text = jsonEncode(res.structuredContent);
    expect(text, isNot(contains('SUPER-SECRET')));
    expect(text, contains('<redacted>'));
  });

  test('network_get redact:false reveals the token (deliberate opt-out)',
      () async {
    final res = await networkGet(CallToolRequest(
        name: 'network_get',
        arguments: {'sessionId': sid, 'id': 'r1', 'redact': false}));
    expect(jsonEncode(res.structuredContent), contains('SUPER-SECRET'));
  });

  test('network_diff never leaks the token, even when it differs', () async {
    // Make r2's token different so it lands in `changed`.
    CapturesDatabase.instance.raw.execute(
      "UPDATE http_requests SET request_headers_json=? WHERE vm_id='r2'",
      [jsonEncode({'authorization': 'Bearer OTHER-SECRET-999'})],
    );
    final res = await networkDiff(CallToolRequest(
        name: 'network_diff',
        arguments: {'sessionId': sid, 'idA': 'r1', 'idB': 'r2'}));
    final text = jsonEncode(res.structuredContent);
    expect(text, isNot(contains('SUPER-SECRET')));
    expect(text, isNot(contains('OTHER-SECRET')));
  });

  test('network_replay redacts by default now', () async {
    final res = await networkReplay(CallToolRequest(
        name: 'network_replay', arguments: {'sessionId': sid, 'id': 'r1'}));
    final curl = res.structuredContent!['curl'].toString();
    expect(curl, isNot(contains('SUPER-SECRET')));
    expect(curl, contains('<redacted>'));
  });

  test('HAR export redacts auth headers when redact:true', () async {
    final out = '${dir.path}/out.har';
    final res = await sessionExport(CallToolRequest(
        name: 'session_export',
        arguments: {'id': sid, 'format': 'har', 'outPath': out,
          'redact': true}));
    expect(res.isError, isFalse);
    final har = File(out).readAsStringSync();
    expect(har, isNot(contains('SUPER-SECRET')));
    expect(har, contains('<redacted>'));
  });

  test('HAR export is faithful (unredacted) by default', () async {
    final out = '${dir.path}/raw.har';
    await sessionExport(CallToolRequest(
        name: 'session_export',
        arguments: {'id': sid, 'format': 'har', 'outPath': out}));
    expect(File(out).readAsStringSync(), contains('SUPER-SECRET'));
  });
}
