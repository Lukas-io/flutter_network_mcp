import 'dart:convert';

import 'package:dart_mcp/server.dart';

/// Builds a [CallToolResult] that carries both a JSON `structuredContent`
/// payload (for the agent to parse) and a pretty-printed text rendering of
/// the same data (so transcripts and inspectors stay readable).
CallToolResult jsonResult(Map<String, Object?> data, {bool isError = false}) {
  final pretty = const JsonEncoder.withIndent('  ').convert(data);
  return CallToolResult(
    content: [TextContent(text: pretty)],
    structuredContent: data,
    isError: isError,
  );
}

CallToolResult errorResult(String message, {Map<String, Object?>? extra}) {
  return jsonResult({
    'error': message,
    if (extra != null) ...extra,
  }, isError: true);
}
