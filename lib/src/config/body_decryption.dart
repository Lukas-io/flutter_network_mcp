import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:pointycastle/export.dart';

/// Where the IV sits in the payload: spliced in at an offset, or at either end.
enum IvMode { infused, prefix, suffix }

/// How the encrypted payload is written in the body.
enum PayloadEncoding { hex, base64, raw }

/// What decrypting one body gave: plaintext, or the raw bytes plus why not.
typedef DecryptOutcome = ({Uint8List bytes, bool decrypted, String? failure});

/// An app-level body encryption scheme (#105). Lives in this process's memory only: the key is never written to the capture DB or echoed back.
class BodyDecryption {
  BodyDecryption._({
    required this.algorithm,
    required Uint8List key,
    required this.encoding,
    required this.ivMode,
    required this.ivOffset,
    required this.ivLength,
  }) : _key = key;

  final String algorithm;
  final Uint8List _key;
  final PayloadEncoding encoding;
  final IvMode ivMode;

  /// Hex: in hex characters of the payload text. Base64 / raw: in decoded bytes.
  final int ivOffset;
  final int ivLength;

  static const _keyBytes = {'aes-256-ctr': 32, 'aes-128-ctr': 16};

  /// Identifies the key in replies without revealing it.
  String get keyFingerprint =>
      sha256.convert(_key).toString().substring(0, 12);

  Map<String, Object?> toBlock() => {
        'active': true,
        'algorithm': algorithm,
        'encoding': encoding.name,
        'ivMode': ivMode.name,
        if (ivMode == IvMode.infused) 'ivOffset': ivOffset,
        'ivLength': ivLength,
        'keyFingerprint': keyFingerprint,
      };

  /// Reads the `bodyDecryption` argument; the config, or a message naming what is wrong.
  static ({BodyDecryption? config, String? error}) parse(Object? raw) {
    if (raw is! Map) {
      return (config: null, error: 'bodyDecryption must be an object');
    }
    final m = raw.cast<String, Object?>();
    final algorithm = ((m['algorithm'] as String?) ?? 'aes-256-ctr').toLowerCase();
    final keyBytes = _keyBytes[algorithm];
    if (keyBytes == null) {
      return (
        config: null,
        error: 'algorithm "$algorithm" is not supported; use aes-256-ctr or aes-128-ctr'
      );
    }
    final keyText = m['key'];
    if (keyText is! String || keyText.isEmpty) {
      return (config: null, error: 'bodyDecryption.key is required');
    }
    final keyEncoding = (m['keyEncoding'] as String?) ?? 'utf8';
    final Uint8List key;
    try {
      key = switch (keyEncoding) {
        'utf8' => Uint8List.fromList(utf8.encode(keyText)),
        'hex' => _hex(keyText),
        'base64' => base64.decode(keyText),
        _ => throw const FormatException('keyEncoding must be utf8, hex or base64'),
      };
    } on FormatException catch (e) {
      return (config: null, error: 'bodyDecryption.key: ${e.message}');
    }
    if (key.length != keyBytes) {
      return (
        config: null,
        error: '$algorithm needs a $keyBytes-byte key; this one is '
            '${key.length} bytes as $keyEncoding'
      );
    }
    final encoding = PayloadEncoding.values
        .where((e) => e.name == ((m['encoding'] as String?) ?? 'hex'))
        .firstOrNull;
    final ivMode = IvMode.values
        .where((e) => e.name == ((m['ivMode'] as String?) ?? 'prefix'))
        .firstOrNull;
    if (encoding == null) {
      return (config: null, error: 'encoding must be hex, base64 or raw');
    }
    if (ivMode == null) {
      return (config: null, error: 'ivMode must be infused, prefix or suffix');
    }
    final unit = encoding == PayloadEncoding.hex ? 2 : 1;
    final ivLength = (m['ivLength'] as num?)?.toInt() ?? 16 * unit;
    final ivOffset = (m['ivOffset'] as num?)?.toInt() ?? 0;
    if (ivLength != 16 * unit) {
      return (
        config: null,
        error: 'AES-CTR takes a 16-byte IV: ivLength must be ${16 * unit}'
            '${unit == 2 ? ' hex characters' : ''}'
      );
    }
    if (ivOffset < 0 || (unit == 2 && ivOffset.isOdd)) {
      return (
        config: null,
        error: 'ivOffset must be a non-negative${unit == 2 ? ', even number of hex characters' : ' byte count'}'
      );
    }
    return (
      config: BodyDecryption._(
        algorithm: algorithm,
        key: key,
        encoding: encoding,
        ivMode: ivMode,
        ivOffset: ivOffset,
        ivLength: ivLength,
      ),
      error: null,
    );
  }

  /// Decrypts one body; on anything that does not fit the scheme, returns [body] untouched with the reason.
  DecryptOutcome decrypt(Uint8List body) {
    DecryptOutcome raw(String why) => (bytes: body, decrypted: false, failure: why);
    final Uint8List iv;
    final Uint8List cipher;
    try {
      final (ivPart, cipherPart) = _split(body);
      iv = ivPart;
      cipher = cipherPart;
    } on FormatException catch (e) {
      return raw(e.message);
    }
    final ctr = CTRStreamCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(_key), iv));
    final plain = ctr.process(cipher);
    try {
      utf8.decode(plain);
    } on FormatException {
      return raw('the result is not UTF-8 text, so the key or scheme does not match this body');
    }
    return (bytes: plain, decrypted: true, failure: null);
  }

  (Uint8List, Uint8List) _split(Uint8List body) {
    switch (encoding) {
      case PayloadEncoding.hex:
        final text = _payloadText(body).toLowerCase();
        if (text.length.isOdd || !RegExp(r'^[0-9a-f]*$').hasMatch(text)) {
          throw const FormatException('the body is not a hex string');
        }
        final (iv, cipher) = _ranges(text.length);
        return (
          _hex(text.substring(iv.$1, iv.$2)),
          _hex(cipher.map((r) => text.substring(r.$1, r.$2)).join()),
        );
      case PayloadEncoding.base64:
        final Uint8List bytes;
        try {
          bytes = base64.decode(_payloadText(body));
        } on FormatException {
          throw const FormatException('the body is not base64');
        }
        return _splitBytes(bytes);
      case PayloadEncoding.raw:
        return _splitBytes(body);
    }
  }

  (Uint8List, Uint8List) _splitBytes(Uint8List bytes) {
    final (iv, cipher) = _ranges(bytes.length);
    return (
      bytes.sublist(iv.$1, iv.$2),
      Uint8List.fromList([for (final r in cipher) ...bytes.sublist(r.$1, r.$2)]),
    );
  }

  /// The IV range and the cipher ranges of a payload [length] units long.
  ((int, int), List<(int, int)>) _ranges(int length) {
    if (length <= ivLength) {
      throw const FormatException('the body is no longer than the IV');
    }
    return switch (ivMode) {
      IvMode.prefix => ((0, ivLength), [(ivLength, length)]),
      IvMode.suffix => ((length - ivLength, length), [(0, length - ivLength)]),
      IvMode.infused => ivOffset + ivLength > length
          ? throw const FormatException('ivOffset + ivLength runs past the body')
          : (
              (ivOffset, ivOffset + ivLength),
              [(0, ivOffset), (ivOffset + ivLength, length)],
            ),
    };
  }

  /// The payload as text: trimmed, and unwrapped when it is a JSON string.
  static String _payloadText(Uint8List body) {
    var text = utf8.decode(body, allowMalformed: true).trim();
    if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
      text = text.substring(1, text.length - 1);
    }
    return text;
  }

  static Uint8List _hex(String s) {
    if (s.length.isOdd) throw const FormatException('odd-length hex');
    final out = Uint8List(s.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final v = int.tryParse(s.substring(i * 2, i * 2 + 2), radix: 16);
      if (v == null) throw const FormatException('not hex');
      out[i] = v;
    }
    return out;
  }
}

/// The scheme this process decrypts bodies with; null when off.
class BodyDecryptionConfig {
  BodyDecryptionConfig._();

  static BodyDecryption? active;
}
