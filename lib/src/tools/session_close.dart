import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import 'result.dart';

final sessionCloseTool = Tool(
  name: 'session_close',
  description:
      'Reverts the read pointer to the live attached session (or no session '
      'if not attached). Does not modify any data. No-op if not currently '
      'viewing history.',
  inputSchema: Schema.object(properties: {}),
);

FutureOr<CallToolResult> sessionClose(CallToolRequest request) async {
  final session = Session.instance;
  final previous = session.viewedSessionId;
  final live = session.liveSessionId;
  session.viewedSessionId = null;

  final summary = previous == null
      ? 'No-op: was not viewing history. Read pointer was already live (${live ?? "none"}).'
      : 'Read pointer reverted from session $previous to live (${live ?? "none"}).';

  return jsonResult({
    'closed': true,
    'summary': summary,
    'previousViewedSessionId': previous,
    'liveSessionId': live,
    'nextSteps': [
      if (live != null) 'network_list — read live captures'
      else 'network_attach — connect to a running app',
      'session_list — see what other sessions exist',
    ],
  });
}
