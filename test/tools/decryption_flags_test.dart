import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_mcp/server.dart';
import 'package:flutter_network_mcp/src/config/body_decryption.dart';
import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/tools/network_diff.dart';
import 'package:flutter_network_mcp/src/tools/network_drift.dart';
import 'package:pointycastle/export.dart';
import 'package:test/test.dart';

const _key = '0123456789abcdef0123456789abcdef';
const _iv = '000102030405060708090a0b0c0d0e0f';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// [plain] as the app would send it: hex IV prefix, then the AES-256-CTR ciphertext in hex.
String _encrypt(String plain) {
  final iv = Uint8List.fromList([for (var i = 0; i < 16; i++) i]);
  final ctr = CTRStreamCipher(AESEngine())
    ..init(true, ParametersWithIV(KeyParameter(Uint8List.fromList(utf8.encode(_key))), iv));
  return '$_iv${_hex(ctr.process(Uint8List.fromList(utf8.encode(plain))))}';
}

/// network_diff and network_drift say whether each body they read was decrypted, like network_body does.
void main() {
  late Directory dir;
  late int sid;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('decryption_flags_test_');
    CapturesDatabase.open(dataDir: dir.path);
    sid = CapturesDao().createSession(
        appName: 'bank', vmServiceUri: 'ws://x', isolateId: null, projectPath: null);
    BodyDecryptionConfig.active =
        BodyDecryption.parse({'key': _key, 'ivMode': 'prefix'}).config;
  });
  tearDown(() {
    BodyDecryptionConfig.active = null;
    CapturesDatabase.instance.close();
    dir.deleteSync(recursive: true);
  });

  void capture(String vmId, int startUs, String body) {
    final raw = CapturesDatabase.instance.raw;
    raw.execute(
      'INSERT INTO http_requests(session_id, vm_id, method, url, host, path, '
      'status_code, content_type, start_us) VALUES (?,?,?,?,?,?,?,?,?)',
      [sid, vmId, 'GET', 'https://api.x/balance', 'api.x', '/balance', 200,
        'text/plain', startUs],
    );
    final bytes = Uint8List.fromList(utf8.encode(body));
    raw.execute(
      'INSERT INTO http_bodies(session_id, vm_id, which, bytes, size) VALUES (?,?,?,?,?)',
      [sid, vmId, 'response', bytes, bytes.length],
    );
  }

  test('network_diff flags each side and warns about a body that did not decrypt', () async {
    capture('a', 1, _encrypt('{"balance":1}'));
    capture('b', 2, 'not encrypted at all');
    final res = await networkDiff(CallToolRequest(
        name: 'network_diff', arguments: {'sessionId': sid, 'idA': 'a', 'idB': 'b'}));
    final sc = res.structuredContent!;
    expect((sc['a'] as Map)['decrypted'], isTrue);
    expect((sc['b'] as Map)['decrypted'], isFalse);
    expect((sc['b'] as Map)['decryptionFailed'], isNotNull);
    expect((sc['warnings'] as List).join(' '), contains('Response body B did not decrypt'));
  });

  test('network_drift reports how many responses decrypted', () async {
    capture('a', 1, _encrypt('{"balance":1}'));
    capture('b', 2, _encrypt('{"balance":1,"currency":"NGN"}'));
    capture('c', 3, 'garbage');
    final res = await networkDrift(CallToolRequest(
        name: 'network_drift', arguments: {'sessionId': sid, 'pathContains': 'balance'}));
    final sc = res.structuredContent!;
    expect(sc['drifted'], isTrue);
    expect(sc['decryption'], {'decrypted': 2, 'failed': 1, 'firstFailure': isA<String>()});
    expect((sc['warnings'] as List).join(' '), contains('did not decrypt'));
  });
}
