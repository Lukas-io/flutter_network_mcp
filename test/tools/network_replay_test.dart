import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_mcp/server.dart';
import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/tools/network_replay.dart';
import 'package:flutter_network_mcp/src/util/body_decoder.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late int sid;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('replay_test_');
    CapturesDatabase.open(dataDir: dir.path);
    sid = CapturesDao().createSession(
        appName: 'app', vmServiceUri: 'ws://x', isolateId: null, projectPath: null);
  });

  tearDown(() {
    CapturesDatabase.instance.close();
    dir.deleteSync(recursive: true);
  });

  void insertRequest(String vmId, List<int> body) {
    CapturesDatabase.instance.raw.execute(
      'INSERT INTO http_requests(session_id, vm_id, method, url, status_code) '
      'VALUES (?,?,?,?,?)',
      [sid, vmId, 'POST', 'https://api.example.com/echo', 200],
    );
    CapturesDatabase.instance.raw.execute(
      'INSERT INTO http_bodies(session_id, vm_id, which, bytes, size) '
      'VALUES (?,?,?,?,?)',
      [sid, vmId, 'request', Uint8List.fromList(body), body.length],
    );
  }

  test('a cut inside a multi-byte character still emits text', () async {
    final body = utf8.encode('abc😀def');
    insertRequest('r1', body);
    final res = await networkReplay(CallToolRequest(
      name: 'network_replay',
      arguments: {'id': 'r1', 'sessionId': sid, 'bodyTruncateBytes': 5},
    ));
    final out = res.structuredContent!;
    expect(out['bodyIsBinary'], isNull);
    expect(out['bodyTruncated'], isTrue);
    expect(out['bodySentSize'], 3);
    expect(out['curl'] as String, contains("--data-raw 'abc'"));
  });

  group('utf8SafeCut', () {
    final bytes = utf8.encode('aé😀');

    test('keeps a cut that lands on a character start', () {
      expect(utf8SafeCut(bytes, 1), 1);
      expect(utf8SafeCut(bytes, 3), 3);
    });

    test('backs off to the start of a split character', () {
      expect(utf8SafeCut(bytes, 2), 1);
      expect(utf8SafeCut(bytes, 6), 3);
    });

    test('returns the full length when nothing is cut', () {
      expect(utf8SafeCut(bytes, 99), bytes.length);
    });
  });
}
