import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../storage/har_exporter.dart';
import 'result.dart';

final sessionExportTool = Tool(
  name: 'session_export',
  description:
      'Writes a session to disk in HAR 1.2 (JSON, openable in Chrome DevTools '
      'or Insomnia) or NDJSON (newline-delimited JSON, one record per line — '
      'good for grep/jq).',
  inputSchema: Schema.object(
    properties: {
      'id': Schema.int(description: 'Session id from session_list.'),
      'format': Schema.string(description: '"har" or "ndjson".'),
      'outPath': Schema.string(description: 'Absolute path to write to.'),
    },
    required: ['id', 'format', 'outPath'],
  ),
);

FutureOr<CallToolResult> sessionExport(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final id = args['id'] as int?;
  final format = args['format'] as String?;
  final outPath = args['outPath'] as String?;
  if (id == null) return errorResult('Missing required arg `id`.');
  if (format == null) return errorResult('Missing required arg `format`.');
  if (outPath == null || outPath.isEmpty) return errorResult('Missing required arg `outPath`.');

  try {
    final written = await exportSession(
      sessionId: id,
      outPath: outPath,
      format: format,
    );
    return jsonResult({
      'exported': true,
      'sessionId': id,
      'format': format,
      'outPath': written,
    });
  } catch (e) {
    return errorResult('export failed: $e');
  }
}
