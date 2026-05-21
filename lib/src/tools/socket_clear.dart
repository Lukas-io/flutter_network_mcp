import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import 'result.dart';

final socketClearTool = Tool(
  name: 'socket_clear',
  description: 'Wipes all captured socket statistics on the attached isolate.',
  inputSchema: Schema.object(properties: {}),
);

FutureOr<CallToolResult> socketClear(CallToolRequest request) async {
  final session = Session.instance;
  if (!session.isAttached) {
    return errorResult('Not attached. Call network_attach first.');
  }
  if (!session.socketProfilingEnabled) {
    return errorResult('Socket profiling is not enabled for this isolate.');
  }
  try {
    await session.vm.clearSocketProfile();
    return jsonResult({'cleared': true});
  } catch (e) {
    return errorResult('clearSocketProfile failed: $e');
  }
}
