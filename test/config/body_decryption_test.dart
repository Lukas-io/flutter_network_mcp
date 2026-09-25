import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_network_mcp/src/config/body_decryption.dart';
import 'package:test/test.dart';

const _key = '0123456789abcdef0123456789abcdef';
const _iv = '000102030405060708090a0b0c0d0e0f';
const _plain = '{"status":"ok","account":"Adaeze Okafor","balance":1520.75}';

/// openssl enc -aes-256-ctr -K <hex of _key> -iv _iv -nosalt, hex-encoded.
const _cipher =
    '287faf81f7bb43172306a522eeab97032733b02277497f77066482b40ffc872b8c543a7b29bd8d50c0dac76bc3223817d3d6aa7c77523faf7b9741';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

BodyDecryption _config(Map<String, Object?> extra) {
  final r = BodyDecryption.parse({'key': _key, 'encoding': 'hex', ...extra});
  expect(r.error, isNull);
  return r.config!;
}

void main() {
  group('#105 AES-256-CTR bodies', () {
    test('infused IV at a hex offset, as the reporter\'s app writes it', () {
      final infused = '${_cipher.substring(0, 10)}$_iv${_cipher.substring(10)}';
      final out = _config({'ivMode': 'infused', 'ivOffset': 10, 'ivLength': 32})
          .decrypt(_bytes(infused));
      expect(out.decrypted, isTrue);
      expect(utf8.decode(out.bytes), _plain);
    });

    test('prefix and suffix IV, and a body sent as a JSON string', () {
      expect(utf8.decode(_config({'ivMode': 'prefix'}).decrypt(_bytes('"$_iv$_cipher"')).bytes), _plain);
      expect(utf8.decode(_config({'ivMode': 'suffix'}).decrypt(_bytes('$_cipher$_iv')).bytes), _plain);
    });

    test('base64 payloads split in decoded bytes', () {
      final hex = '$_iv$_cipher';
      final bytes = [for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];
      final out = _config({'encoding': 'base64', 'ivMode': 'prefix'})
          .decrypt(_bytes(base64.encode(bytes)));
      expect(utf8.decode(out.bytes), _plain);
    });

    test('a wrong key or a plain body comes back raw with the reason', () {
      final wrong = BodyDecryption.parse({'key': 'x' * 32, 'ivMode': 'prefix'}).config!;
      final bad = wrong.decrypt(_bytes('$_iv$_cipher'));
      expect(bad.decrypted, isFalse);
      expect(bad.failure, contains('not UTF-8'));
      expect(utf8.decode(bad.bytes), '$_iv$_cipher');

      final plainBody = _config({'ivMode': 'prefix'}).decrypt(_bytes('{"error":"x"}'));
      expect(plainBody.failure, 'the body is not a hex string');
    });

    test('config errors name the problem, and the reply never carries the key', () {
      expect(BodyDecryption.parse({'key': 'short'}).error, contains('32-byte key'));
      expect(BodyDecryption.parse({'key': _key, 'algorithm': 'des'}).error, contains('not supported'));
      expect(BodyDecryption.parse({'key': _key, 'ivMode': 'infused', 'ivOffset': 3}).error, contains('even'));
      final block = _config({'ivMode': 'infused', 'ivOffset': 10}).toBlock();
      expect(jsonEncode(block), isNot(contains(_key)));
      expect(block['keyFingerprint'], hasLength(12));
    });
  });
}
