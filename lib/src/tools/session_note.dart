import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../storage/captures_db.dart';
import 'result.dart';

final sessionNoteTool = Tool(
  name: 'session_note',
  description:
      'Sets a freeform note on a capture session. Helps you (and future-you) '
      'remember what a session was about — "auth bug 2026-05-21", "release '
      'smoke test", etc. Pass an empty string to clear.',
  inputSchema: Schema.object(
    properties: {
      'id': Schema.int(description: 'Session id.'),
      'note': Schema.string(description: 'The note text. Empty string clears.'),
    },
    required: ['id', 'note'],
  ),
);

FutureOr<CallToolResult> sessionNote(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final id = args['id'] as int?;
  final note = args['note'] as String?;
  if (id == null) return errorResult('Missing required arg `id`.');
  if (note == null) return errorResult('Missing required arg `note`.');

  final dao = CapturesDao();
  if (dao.getSession(id) == null) {
    return errorResult('Session $id not found.');
  }
  dao.setSessionNote(id, note.isEmpty ? null : note);
  return jsonResult({'sessionId': id, 'note': note.isEmpty ? null : note});
}
