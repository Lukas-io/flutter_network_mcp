import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import 'result.dart';

final networkClearTool = Tool(
  name: 'network_clear',
  description:
      'Wipes all captured HTTP requests on the attached isolate and resets '
      'the session cursor. Requests in flight after clearing are ignored by '
      'the profiler.',
  inputSchema: Schema.object(properties: {}),
);

FutureOr<CallToolResult> networkClear(CallToolRequest request) async {
  final session = Session.instance;
  if (!session.isAttached) {
    return errorResult('Not attached. Call network_attach first.');
  }
  try {
    await session.vm.clearHttpProfile();
    session.lastHttpCursor = null;
    return jsonResult({'cleared': true});
  } catch (e) {
    return errorResult('clearHttpProfile failed: $e');
  }
}
