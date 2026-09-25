import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_mcp/server.dart';
import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/tools/network_body.dart';
import 'package:flutter_network_mcp/src/tools/network_get.dart';
import 'package:test/test.dart';

/// A JSON upload whose response is an image: the request body must be decoded
/// with the request's own content type, not the response's.
void main() {
  late Directory dir;
  late int sid;
  const requestJson = '{"name":"avatar"}';

  setUp(() {
    dir = Directory.systemTemp.createTempSync('request_ct_test_');
    CapturesDatabase.open(dataDir: dir.path);
    sid = CapturesDao().createSession(
        appName: 'app', vmServiceUri: 'ws://x', isolateId: null, projectPath: null);
    final raw = CapturesDatabase.instance.raw;
    raw.execute(
      'INSERT INTO http_requests(session_id, vm_id, method, url, status_code, '
      'start_us, end_us, content_type, request_headers_json, response_headers_json) '
      'VALUES (?,?,?,?,?,?,?,?,?,?)',
      [
        sid,
        'r1',
        'POST',
        'https://api.example.com/avatar',
        200,
        1000,
        2000,
        'image/png',
        jsonEncode({'content-type': ['application/json']}),
        jsonEncode({'content-type': ['image/png']}),
      ],
    );
    final body = Uint8List.fromList(utf8.encode(requestJson));
    raw.execute(
      'INSERT INTO http_bodies(session_id, vm_id, which, bytes, size) '
      'VALUES (?,?,?,?,?)',
      [sid, 'r1', 'request', body, body.length],
    );
  });

  tearDown(() {
    CapturesDatabase.instance.close();
    dir.deleteSync(recursive: true);
  });

  test('history network_get decodes the request body as JSON text', () async {
    final res = await networkGet(CallToolRequest(
      name: 'network_get',
      arguments: {'id': 'r1', 'sessionId': sid},
    ));
    final body = ((res.structuredContent!['request'] as Map)['body'] as Map);
    expect(body['encoding'], 'utf8');
    expect(body['value'], contains('avatar'));
    expect(body['mimeType'], 'application/json');
  });

  test('history network_body which:request reports the request mimeType', () async {
    final res = await networkBody(CallToolRequest(
      name: 'network_body',
      arguments: {'id': 'r1', 'sessionId': sid, 'which': 'request'},
    ));
    final out = res.structuredContent!;
    expect(out['mimeType'], 'application/json');
    expect(out['encoding'], 'utf8');
    expect(out['value'], requestJson);
  });
}
