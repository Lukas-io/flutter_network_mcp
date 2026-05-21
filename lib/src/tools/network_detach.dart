import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../storage/captures_db.dart';
import 'result.dart';

final networkDetachTool = Tool(
  name: 'network_detach',
  description:
      'Closes DTD + VM service connections, stops the capture writer, and '
      'marks the live session as ended in the database. The session and all '
      'captured data remain queryable via session_list / session_open.',
  inputSchema: Schema.object(properties: {}),
);

FutureOr<CallToolResult> networkDetach(CallToolRequest request) async {
  final session = Session.instance;
  final wasAttached = session.isAttached;
  final endedSession = session.liveSessionId;
  if (endedSession != null) {
    try {
      CapturesDao().endSession(endedSession);
    } catch (_) {/* DB may already be closed */}
  }
  await session.detach();
  return jsonResult({
    'detached': true,
    'wasAttached': wasAttached,
    'endedSessionId': endedSession,
  });
}
