import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import 'result.dart';

final sessionCloseTool = Tool(
  name: 'session_close',
  description:
      'Reverts the read pointer to the live attached session (or no session '
      'if not attached). Does not modify any data.',
  inputSchema: Schema.object(properties: {}),
);

FutureOr<CallToolResult> sessionClose(CallToolRequest request) async {
  final session = Session.instance;
  final previous = session.viewedSessionId;
  session.viewedSessionId = null;
  return jsonResult({
    'closed': true,
    'previousViewedSessionId': previous,
    'liveSessionId': session.liveSessionId,
  });
}
