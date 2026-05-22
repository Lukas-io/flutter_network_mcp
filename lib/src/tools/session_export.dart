import 'dart:async';
import 'dart:io' as io;

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../storage/captures_db.dart';
import '../storage/har_exporter.dart';
import 'result.dart';

final sessionExportTool = Tool(
  name: 'session_export',
  description:
      'Writes a session to disk as HAR 1.2 (JSON, openable in Chrome '
      'DevTools / Insomnia / Postman) or NDJSON (one record per line — good '
      'for grep/jq). Creates parent directories as needed.',
  inputSchema: Schema.object(
    properties: {
      'id': Schema.int(description: 'Session id (from session_list).'),
      'format': Schema.string(description: '"har" | "ndjson".'),
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

  if (id == null) {
    return errorResult('Missing required arg `id`.', extra: const {
      'nextSteps': ['session_list — find a session id'],
    });
  }
  if (format == null || (format != 'har' && format != 'ndjson')) {
    return errorResult('`format` must be "har" or "ndjson".', extra: const {
      'nextSteps': [
        'Retry with format:"har" (Chrome DevTools / Insomnia compatible)',
        'Retry with format:"ndjson" (one record per line for grep/jq)',
      ],
    });
  }
  if (outPath == null || outPath.isEmpty) {
    return errorResult('Missing required arg `outPath`.', extra: const {
      'nextSteps': ['Retry with an absolute path, e.g. outPath:"/tmp/session.har"'],
    });
  }

  // Pre-flight check the session exists so the error is clean.
  final session = Session.instance;
  final dao = CapturesDao();
  final row = dao.getSessionWithCounts(id);
  if (row == null) {
    return errorResult('Session $id not found.', extra: const {
      'nextSteps': ['session_list — see valid ids'],
    });
  }
  final isLive = session.liveSessionId == id && row['ended_at'] == null;
  final fileExists = io.File(outPath).existsSync();

  try {
    final written = await exportSession(
      sessionId: id,
      outPath: outPath,
      format: format,
    );
    final sizeBytes = io.File(written).lengthSync();
    final httpCount = row['http_count'] ?? 0;
    final logCount = row['log_count'] ?? 0;
    final socketCount = row['socket_count'] ?? 0;

    final summary = 'Exported session $id ($httpCount http, $logCount log(s), $socketCount socket(s)) '
        'to $written ($format, $sizeBytes bytes).';

    final warnings = <String>[];
    if (isLive) {
      warnings.add(
        'Session is still live — the export is a snapshot. Detach first for a stable end_at.',
      );
    }
    if (fileExists) {
      warnings.add('Overwrote existing file at $written.');
    }
    if (format == 'har' && (httpCount as int) == 0) {
      warnings.add('Session has no HTTP requests — the HAR file will have an empty entries[] array.');
    }

    return jsonResult({
      'summary': summary,
      'exported': true,
      'sessionId': id,
      'format': format,
      'outPath': written,
      'sizeBytes': sizeBytes,
      'counts': {'http': httpCount, 'sockets': socketCount, 'logs': logCount},
      if (warnings.isNotEmpty) 'warnings': warnings,
      'nextSteps': [
        if (format == 'har')
          'Open $written in Chrome DevTools (Network tab → Import HAR)'
        else
          'cat $written | jq ... — explore with standard CLI tools',
        'session_note id:$id note:"..." — annotate before sharing',
      ],
    });
  } catch (e) {
    return errorResult('export failed: $e', extra: {
      'sessionId': id,
      'outPath': outPath,
      'nextSteps': const [
        'Confirm the outPath parent directory is writable',
        'session_list — confirm session id is valid',
      ],
    });
  }
}
