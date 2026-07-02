import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import '../util/body_decoder.dart';
import 'captures_db.dart';
import 'database.dart';

/// Exports a session to HAR 1.2 (JSON) or NDJSON. Returns the path written.
class HarExporter {
  HarExporter(this._dao);

  final CapturesDao _dao;

  Future<String> export({
    required int sessionId,
    required String outPath,
    required String format,
    Set<String> redactNames = const {},
  }) async {
    if (format != 'har' && format != 'ndjson') {
      throw ArgumentError('format must be "har" or "ndjson", got "$format".');
    }
    final session = _dao.getSession(sessionId);
    if (session == null) {
      throw ArgumentError('Session $sessionId not found.');
    }
    final requests = _dao.queryHttpRequests(sessionId: sessionId, limit: 100000);

    final file = io.File(outPath);
    file.parent.createSync(recursive: true);

    if (format == 'har') {
      final har = _toHar(session, requests, redactNames);
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(har));
    } else {
      final sink = file.openWrite();
      try {
        sink.writeln(jsonEncode({'type': 'session', ...session}));
        for (final r in requests) {
          sink.writeln(jsonEncode({'type': 'request', ..._redactRow(r, redactNames)}));
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
    }
    return outPath;
  }

  Map<String, Object?> _toHar(
    Map<String, Object?> session,
    List<Map<String, Object?>> requests,
    Set<String> redactNames,
  ) {
    return {
      'log': {
        'version': '1.2',
        'creator': {'name': 'flutter_network_mcp', 'version': '0.3.0'},
        'browser': {
          'name': (session['app_name'] as String?) ?? 'Flutter app',
          'version': '',
        },
        'pages': const <dynamic>[],
        'entries': [
          for (final r in requests)
            _entryFor(session['id'] as int, r, redactNames),
        ],
      },
    };
  }

  Map<String, Object?> _entryFor(
      int sessionId, Map<String, Object?> r, Set<String> redactNames) {
    final vmId = r['vm_id'] as String;
    final startUs = r['start_us'] as int?;
    final endUs = r['end_us'] as int?;
    final durationMs = endUs == null || startUs == null
        ? -1
        : ((endUs - startUs) / 1000).round();
    final reqHeaders = _parseHeaders(r['request_headers_json']);
    final respHeaders = _parseHeaders(r['response_headers_json']);
    final reqBody = _dao.getBody(sessionId, vmId, 'request');
    final respBody = _dao.getBody(sessionId, vmId, 'response');
    final reqContentType = _firstHeader(reqHeaders, 'content-type');
    final respContentType = _firstHeader(respHeaders, 'content-type');

    return {
      'startedDateTime':
          startUs == null
              ? '1970-01-01T00:00:00.000Z'
              : DateTime.fromMicrosecondsSinceEpoch(startUs).toUtc().toIso8601String(),
      'time': durationMs,
      'request': {
        'method': r['method'] ?? '',
        'url': r['url'] ?? '',
        'httpVersion': 'HTTP/1.1',
        'cookies': const <dynamic>[],
        'headers': _harHeaders(reqHeaders, redactNames),
        'queryString': _queryFor(r['url'] as String?),
        'headersSize': -1,
        'bodySize': r['request_size'] ?? -1,
        if (reqBody != null) 'postData': _postData(reqBody, reqContentType),
      },
      'response': {
        'status': r['status_code'] ?? 0,
        'statusText': r['reason_phrase'] ?? '',
        'httpVersion': 'HTTP/1.1',
        'cookies': const <dynamic>[],
        'headers': _harHeaders(respHeaders, redactNames),
        'content': _content(respBody, respContentType),
        // F22: fill redirectURL from the last hop's Location when the
        // request followed a chain (dart:io collapses it into one entry).
        'redirectURL': _lastRedirectLocation(r['redirects_json'] as String?),
        'headersSize': -1,
        'bodySize': r['response_size'] ?? -1,
      },
      'cache': const <String, dynamic>{},
      'timings': {
        'send': 0,
        'wait': durationMs < 0 ? -1 : durationMs,
        'receive': 0,
      },
    };
  }

  Map<String, Object?> _postData(Uint8List body, String? mimeType) {
    final decoded = decodeBody(body, mimeType, maxBytes: -1, semantic: false);
    if (decoded == null) {
      return {
        'mimeType': mimeType ?? 'application/octet-stream',
        'text': '',
      };
    }
    if (decoded.encoding == 'utf8') {
      return {
        'mimeType': mimeType ?? 'application/octet-stream',
        'text': decoded.value,
      };
    }
    return {
      'mimeType': mimeType ?? 'application/octet-stream',
      'text': decoded.value,
      'encoding': 'base64',
    };
  }

  Map<String, Object?> _content(Uint8List? body, String? mimeType) {
    if (body == null || body.isEmpty) {
      return {
        'size': 0,
        'mimeType': mimeType ?? '',
        'text': '',
      };
    }
    final decoded = decodeBody(body, mimeType, maxBytes: -1, semantic: false);
    if (decoded == null) {
      return {'size': body.length, 'mimeType': mimeType ?? '', 'text': ''};
    }
    return {
      'size': decoded.totalSize,
      'mimeType': mimeType ?? '',
      if (decoded.encoding == 'utf8') 'text': decoded.value,
      if (decoded.encoding == 'base64') ...{
        'text': decoded.value,
        'encoding': 'base64',
      },
    };
  }

  /// F22: the Location of the final redirect hop, or '' when none. dart:io
  /// collapses a followed chain into one profile entry, so this is an
  /// approximation of the HAR redirectURL field (the last known target).
  String _lastRedirectLocation(String? redirectsJson) {
    if (redirectsJson == null || redirectsJson.isEmpty) return '';
    try {
      final decoded = jsonDecode(redirectsJson);
      if (decoded is List && decoded.isNotEmpty) {
        final last = decoded.last;
        if (last is Map && last['location'] is String) {
          return last['location'] as String;
        }
      }
    } catch (_) {/* malformed — no redirectURL */}
    return '';
  }

  List<Map<String, Object?>> _harHeaders(
      Map<String, dynamic>? headers, Set<String> redactNames) {
    if (headers == null) return const [];
    final out = <Map<String, Object?>>[];
    for (final e in headers.entries) {
      if (redactNames.contains(e.key.toLowerCase())) {
        out.add({'name': e.key, 'value': '<redacted>'});
        continue;
      }
      final v = e.value;
      if (v is List) {
        for (final item in v) {
          out.add({'name': e.key, 'value': item?.toString() ?? ''});
        }
      } else {
        out.add({'name': e.key, 'value': v?.toString() ?? ''});
      }
    }
    return out;
  }

  /// Redacts auth header VALUES inside the raw *_headers_json columns for the
  /// NDJSON export path (D5).
  Map<String, Object?> _redactRow(
      Map<String, Object?> r, Set<String> redactNames) {
    if (redactNames.isEmpty) return r;
    final out = Map<String, Object?>.of(r);
    for (final col in ['request_headers_json', 'response_headers_json']) {
      final raw = out[col];
      final parsed = _parseHeaders(raw);
      if (parsed == null) continue;
      final masked = <String, dynamic>{};
      parsed.forEach((k, v) {
        masked[k] = redactNames.contains(k.toLowerCase()) ? '<redacted>' : v;
      });
      out[col] = jsonEncode(masked);
    }
    return out;
  }

  List<Map<String, Object?>> _queryFor(String? url) {
    if (url == null) return const [];
    try {
      final uri = Uri.parse(url);
      return [
        for (final e in uri.queryParametersAll.entries)
          for (final v in e.value) {'name': e.key, 'value': v},
      ];
    } catch (_) {
      return const [];
    }
  }

  Map<String, dynamic>? _parseHeaders(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  String? _firstHeader(Map<String, dynamic>? headers, String name) {
    if (headers == null) return null;
    final target = name.toLowerCase();
    for (final e in headers.entries) {
      if (e.key.toLowerCase() == target) {
        final v = e.value;
        if (v is List && v.isNotEmpty) return v.first.toString();
        return v?.toString();
      }
    }
    return null;
  }
}

/// Convenience: open the DB if needed and run an export.
Future<String> exportSession({
  required int sessionId,
  required String outPath,
  required String format,
  bool redact = false,
}) {
  CapturesDatabase.instance;
  return HarExporter(CapturesDao()).export(
    sessionId: sessionId,
    outPath: outPath,
    format: format,
    redactNames: redact ? CapturesDao().redactedHeaderSet() : const {},
  );
}
