import 'dart:convert';
import 'dart:typed_data';

/// Outcome of decoding a body for transport over MCP.
///
/// `value` is either a UTF-8 string (when the body is textual and fits the
/// caller's truncation budget) or a base64 string. `truncated` is true when
/// `size` < `totalSize`.
class DecodedBody {
  const DecodedBody({
    required this.encoding,
    required this.value,
    required this.size,
    required this.totalSize,
    required this.truncated,
    this.mimeType,
  });

  final String encoding; // 'utf8' or 'base64'
  final String value;
  final int size;
  final int totalSize;
  final bool truncated;
  final String? mimeType;

  Map<String, Object?> toJson() => {
        'encoding': encoding,
        'size': size,
        'totalSize': totalSize,
        'truncated': truncated,
        if (mimeType != null) 'mimeType': mimeType,
        'value': value,
      };
}

DecodedBody? decodeBody(
  Uint8List? bytes,
  String? contentType, {
  int? maxBytes,
  String decode = 'auto', // 'auto' | 'utf8' | 'base64'
}) {
  if (bytes == null || bytes.isEmpty) return null;
  final total = bytes.length;
  final cap = (maxBytes == null || maxBytes < 0) ? total : maxBytes;
  final sliceLen = cap < total ? cap : total;
  final slice = sliceLen == total ? bytes : Uint8List.sublistView(bytes, 0, sliceLen);
  final truncated = sliceLen < total;

  final wantUtf8 = decode == 'utf8' ||
      (decode == 'auto' && _isTextContentType(contentType));

  if (wantUtf8) {
    try {
      return DecodedBody(
        encoding: 'utf8',
        value: utf8.decode(slice, allowMalformed: true),
        size: sliceLen,
        totalSize: total,
        truncated: truncated,
        mimeType: contentType,
      );
    } catch (_) {
      // Fall through to base64.
    }
  }

  return DecodedBody(
    encoding: 'base64',
    value: base64.encode(slice),
    size: sliceLen,
    totalSize: total,
    truncated: truncated,
    mimeType: contentType,
  );
}

bool _isTextContentType(String? contentType) {
  if (contentType == null) return false;
  final ct = contentType.toLowerCase();
  return ct.contains('application/json') ||
      ct.contains('application/xml') ||
      ct.contains('application/x-www-form-urlencoded') ||
      ct.contains('application/javascript') ||
      ct.contains('application/graphql') ||
      ct.contains('application/ld+json') ||
      ct.contains('application/vnd.api+json') ||
      ct.contains('application/problem+json') ||
      ct.startsWith('text/');
}

/// Compresses a JSON header map into a context-safe form. Each value is
/// truncated to [maxValueBytes] (default 256). A `_truncated` field is added
/// alongside the affected key when truncation happens. List values are
/// joined with ", ".
Map<String, Object?>? truncateHeaders(
  Map<String, dynamic>? headers, {
  int maxValueBytes = 256,
  int maxHeaders = 64,
}) {
  if (headers == null) return null;
  final out = <String, Object?>{};
  var i = 0;
  for (final e in headers.entries) {
    if (i++ >= maxHeaders) {
      out['_omitted'] = headers.length - maxHeaders;
      break;
    }
    final v = e.value;
    final flat = v is List ? v.join(', ') : (v?.toString() ?? '');
    if (flat.length > maxValueBytes) {
      out[e.key] = {
        'value': flat.substring(0, maxValueBytes),
        'truncated': true,
        'totalLength': flat.length,
      };
    } else {
      out[e.key] = flat;
    }
  }
  return out;
}

String? firstHeader(Map<String, dynamic>? headers, String name) {
  if (headers == null) return null;
  final target = name.toLowerCase();
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == target) {
      final v = entry.value;
      if (v is List && v.isNotEmpty) return v.first.toString();
      return v?.toString();
    }
  }
  return null;
}
