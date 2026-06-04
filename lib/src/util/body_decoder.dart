import 'dart:convert';
import 'dart:typed_data';

import 'semantic_truncate.dart';

/// Outcome of decoding a body for transport over MCP.
///
/// `value` is either a UTF-8 string (when the body is textual and fits the
/// caller's truncation budget) or a base64 string. `truncated` is true when
/// any content was dropped — either byte-cap truncation or 0.7.0+
/// semantic-aware truncation (collapsed arrays, clipped long strings,
/// stripped HTML noise). `truncationMode` says which path ran.
class DecodedBody {
  const DecodedBody({
    required this.encoding,
    required this.value,
    required this.size,
    required this.totalSize,
    required this.truncated,
    this.truncationMode,
    this.mimeType,
  });

  final String encoding; // 'utf8' or 'base64'
  final String value;
  final int size;
  final int totalSize;
  final bool truncated;

  /// 'semantic' when 0.7.0 JSON/HTML truncation ran, 'byte' when the legacy
  /// byte-cap path ran, null when nothing was truncated.
  final String? truncationMode;
  final String? mimeType;

  Map<String, Object?> toJson() => {
        'encoding': encoding,
        'size': size,
        'totalSize': totalSize,
        'truncated': truncated,
        if (truncationMode != null) 'truncationMode': truncationMode,
        if (mimeType != null) 'mimeType': mimeType,
        'value': value,
      };
}

/// Decodes a captured body for transport.
///
/// **Semantic truncation (0.7.0+).** For JSON / HTML payloads the default
/// path now collapses arrays past 5 elements, clips string leaves > 200
/// chars, strips `<script>` / `<style>` / comments / whitespace runs —
/// preserving structure while bounding output. Set [semantic] to `false`
/// to force the legacy byte-cap behavior (used by `network_body` which
/// needs byte-exact paging).
DecodedBody? decodeBody(
  Uint8List? bytes,
  String? contentType, {
  int? maxBytes,
  String decode = 'auto', // 'auto' | 'utf8' | 'base64'
  bool semantic = true,
}) {
  if (bytes == null || bytes.isEmpty) return null;
  final total = bytes.length;
  final cap = (maxBytes == null || maxBytes < 0) ? total : maxBytes;

  final wantUtf8 = decode == 'utf8' ||
      (decode == 'auto' && _isTextContentType(contentType));

  // Semantic path: decode all bytes, run JSON/HTML truncator, fall back
  // to byte-cap if the truncator says it didn't apply. Bounded by
  // kSemanticInputCap so a giant body doesn't blow the JSON parser. Also
  // bypassed when cap >= total (caller passed -1 or a roomy budget) —
  // semantic truncation would needlessly reformat a payload that already
  // fits.
  if (wantUtf8 && semantic && total <= kSemanticInputCap && cap < total) {
    final full = utf8.decode(bytes, allowMalformed: true);
    SemanticTruncation? attempt;
    if (_isJsonContentType(contentType)) {
      attempt = truncateJson(full, maxBytes: cap);
    } else if (_isHtmlContentType(contentType)) {
      attempt = truncateHtml(full, maxBytes: cap);
    }
    if (attempt != null && attempt.didApply) {
      return DecodedBody(
        encoding: 'utf8',
        value: attempt.value,
        size: attempt.value.length,
        totalSize: total,
        truncated: attempt.truncated,
        truncationMode: attempt.truncated ? 'semantic' : null,
        mimeType: contentType,
      );
    }
    // Else: fall through to byte-cap.
  }

  // Byte-cap path (legacy). Slice then decode.
  final sliceLen = cap < total ? cap : total;
  final slice = sliceLen == total ? bytes : Uint8List.sublistView(bytes, 0, sliceLen);
  final truncated = sliceLen < total;

  if (wantUtf8) {
    try {
      return DecodedBody(
        encoding: 'utf8',
        value: utf8.decode(slice, allowMalformed: true),
        size: sliceLen,
        totalSize: total,
        truncated: truncated,
        truncationMode: truncated ? 'byte' : null,
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
    truncationMode: truncated ? 'byte' : null,
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

bool _isJsonContentType(String? contentType) {
  if (contentType == null) return false;
  final ct = contentType.toLowerCase();
  return ct.contains('application/json') ||
      ct.contains('application/ld+json') ||
      ct.contains('application/vnd.api+json') ||
      ct.contains('application/problem+json') ||
      ct.contains('application/graphql');
}

bool _isHtmlContentType(String? contentType) {
  if (contentType == null) return false;
  final ct = contentType.toLowerCase();
  return ct.contains('text/html') || ct.contains('application/xhtml');
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
