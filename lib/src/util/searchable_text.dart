import 'dart:convert';
import 'dart:typed_data';

import '../config/body_decryption.dart';

/// The text a body contributes to search: its plaintext when body decryption is on and the body decrypts, else the body itself when its content type is textual; null when there is nothing to index.
String? searchableText(Uint8List? bytes, String? contentType) {
  if (bytes == null || bytes.isEmpty) return null;
  final scheme = BodyDecryptionConfig.active;
  if (scheme != null) {
    final out = scheme.decrypt(bytes);
    if (out.decrypted) return utf8.decode(out.bytes);
  }
  final ct = contentType?.toLowerCase() ?? '';
  final textish = ct.contains('json') ||
      ct.contains('xml') ||
      ct.contains('text') ||
      ct.contains('javascript') ||
      ct.contains('graphql') ||
      ct.contains('form-urlencoded');
  if (!textish) return null;
  return utf8.decode(bytes, allowMalformed: true);
}
