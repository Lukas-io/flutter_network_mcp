import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_mcp/server.dart';
import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/tools/network_replay_as_test.dart';
import 'package:test/test.dart';

/// 0.9.4: captured request -> runnable Dart test.
void main() {
  late Directory dir;
  late CapturesDao dao;
  late int sid;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('replay_as_test_');
    CapturesDatabase.open(dataDir: dir.path);
    dao = CapturesDao();
    sid = dao.createSession(
      appName: 'app',
      vmServiceUri: 'ws://x',
      isolateId: null,
      projectPath: null,
    );
    CapturesDatabase.instance.raw.execute(
      'INSERT INTO http_requests(session_id, vm_id, method, url, host, path, '
      'status_code, content_type, request_headers_json) '
      'VALUES (?,?,?,?,?,?,?,?,?)',
      [
        sid,
        'r1',
        'POST',
        'https://api.example.com/login',
        'api.example.com',
        '/login',
        200,
        'application/json',
        jsonEncode({
          'content-type': 'application/json',
          'authorization': 'Bearer secret',
        }),
      ],
    );
    final body = Uint8List.fromList(utf8.encode('{"user":"a"}'));
    CapturesDatabase.instance.raw.execute(
      'INSERT INTO http_bodies(session_id, vm_id, which, bytes, size) '
      'VALUES (?,?,?,?,?)',
      [sid, 'r1', 'request', body, body.length],
    );
  });

  tearDown(() {
    CapturesDatabase.instance.close();
    dir.deleteSync(recursive: true);
  });

  test('emits a runnable Dart test that asserts the captured status', () async {
    final res = await networkReplayAsTest(CallToolRequest(
      name: 'network_replay_as_test',
      arguments: {'id': 'r1', 'sessionId': sid},
    ));
    expect(res.isError, isFalse);
    final code = res.structuredContent!['test'] as String;
    expect(code, contains("import 'package:test/test.dart';"));
    expect(code,
        contains("http.Request('POST', Uri.parse('https://api.example.com/login'))"));
    expect(code, contains('expect(response.statusCode, 200);'));
    expect(code, contains("request.body = '{\"user\":\"a\"}';"));
    // authorization is redacted (commented out) by default
    expect(code, contains("// 'authorization': '<fill in: redacted>',"));
    expect(code, contains("'content-type': 'application/json',"));
  });

  test('assertBodyContains adds a body assertion', () async {
    final res = await networkReplayAsTest(CallToolRequest(
      name: 'network_replay_as_test',
      arguments: {'id': 'r1', 'sessionId': sid, 'assertBodyContains': 'token'},
    ));
    final code = res.structuredContent!['test'] as String;
    expect(code, contains("expect(response.body, contains('token'));"));
  });

  void insertRequest(String vmId, String url, List<int> body) {
    CapturesDatabase.instance.raw.execute(
      'INSERT INTO http_requests(session_id, vm_id, method, url, status_code) '
      'VALUES (?,?,?,?,?)',
      [sid, vmId, 'POST', url, 200],
    );
    CapturesDatabase.instance.raw.execute(
      'INSERT INTO http_bodies(session_id, vm_id, which, bytes, size) '
      'VALUES (?,?,?,?,?)',
      [sid, vmId, 'request', Uint8List.fromList(body), body.length],
    );
  }

  Future<Map<String, Object?>> replay(String id) async =>
      (await networkReplayAsTest(CallToolRequest(
        name: 'network_replay_as_test',
        arguments: {'id': id, 'sessionId': sid},
      )))
          .structuredContent!;

  test(r'test name escapes $ so it is not an interpolation', () async {
    insertRequest('r2', r'https://api.example.com/price/$total', utf8.encode('x'));
    final code = (await replay('r2'))['test'] as String;
    expect(code, contains(r"test('POST /price/\$total replays'"));
  });

  test('a body cut inside a multi-byte character keeps the text', () async {
    final body = utf8.encode('${'a' * 8191}é tail');
    insertRequest('r3', 'https://api.example.com/text', body);
    final out = await replay('r3');
    final code = out['test'] as String;
    expect(code, contains("request.body = '${'a' * 8191}';"));
    expect(out['bodyIsBinary'], isNull);
    expect((out['warnings'] as List).join(' '), contains('8191 of ${body.length}'));
  });

  test('a binary body is reported, not silently dropped', () async {
    insertRequest('r4', 'https://api.example.com/bin', [0xff, 0xfe, 0x00, 0x81]);
    final out = await replay('r4');
    expect(out['bodyIsBinary'], isTrue);
    expect((out['test'] as String), isNot(contains('request.body')));
    expect((out['warnings'] as List).join(' '), contains('not UTF-8'));
  });

  test('unknown id -> errorKind not_found', () async {
    final res = await networkReplayAsTest(CallToolRequest(
      name: 'network_replay_as_test',
      arguments: {'id': 'nope', 'sessionId': sid},
    ));
    expect(res.isError, isTrue);
    expect(res.structuredContent!['errorKind'], 'not_found');
  });
}
