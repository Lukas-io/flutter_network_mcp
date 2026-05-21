import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import 'result.dart';

final logsClearTool = Tool(
  name: 'logs_clear',
  description:
      'Empties the in-memory log ring buffer. Does NOT affect the app — '
      'new log/stdout/stderr events will continue to fill the buffer.',
  inputSchema: Schema.object(properties: {}),
);

FutureOr<CallToolResult> logsClear(CallToolRequest request) async {
  Session.instance.logBuffer.clear();
  return jsonResult({'cleared': true});
}
