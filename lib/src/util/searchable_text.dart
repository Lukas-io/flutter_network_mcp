import 'dart:convert';
import 'dart:typed_data';

/// The text a body contributes to the capture DB's search index: the body itself when its content type is textual, else null. Never decrypted plaintext; that lives only in [PlaintextIndex].
String? searchableText(Uint8List? bytes, String? contentType) {
  if (bytes == null || bytes.isEmpty) return null;
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
