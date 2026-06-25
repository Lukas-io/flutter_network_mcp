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
      final har = _toHar(session, requests);
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(har));
    } else {
      final sink = file.openWrite();
      try {
        sink.writeln(jsonEncode({'type': 'session', ...session}));
        for (final r in requests) {
          sink.writeln(jsonEncode({'type': 'request', ...r}));
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
          for (final r in requests) _entryFor(session['id'] as int, r),
        ],
      },
    };
  }

  Map<String, Object?> _entryFor(int sessionId, Map<String, Object?> r) {
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
        'headers': _harHeaders(reqHeaders),
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
        'headers': _harHeaders(respHeaders),
        'content': _content(respBody, respContentType),
        'redirectURL': '',
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

  List<Map<String, Object?>> _harHeaders(Map<String, dynamic>? headers) {
    if (headers == null) return const [];
    final out = <Map<String, Object?>>[];
    for (final e in headers.entries) {
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
}) {
  CapturesDatabase.instance;
  return HarExporter(CapturesDao()).export(
    sessionId: sessionId,
    outPath: outPath,
    format: format,
  );
}
