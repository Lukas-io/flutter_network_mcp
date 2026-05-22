import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../storage/captures_db.dart';
import 'result.dart';

final sessionNoteTool = Tool(
  name: 'session_note',
  description:
      'Sets (or clears) a freeform note on a capture session. Helps you '
      'find sessions later via session_list. Pass an empty string to clear.',
  inputSchema: Schema.object(
    properties: {
      'id': Schema.int(description: 'Session id.'),
      'note': Schema.string(
        description: 'Free text. Empty string clears any existing note.',
      ),
    },
    required: ['id', 'note'],
  ),
);

FutureOr<CallToolResult> sessionNote(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final id = args['id'] as int?;
  final note = args['note'] as String?;
  if (id == null) {
    return errorResult('Missing required arg `id`.', extra: const {
      'nextSteps': ['session_list — find a session id'],
    });
  }
  if (note == null) {
    return errorResult('Missing required arg `note`.', extra: const {
      'nextSteps': ['Retry with note:"" to clear, or note:"<your text>" to set'],
    });
  }

  final dao = CapturesDao();
  final row = dao.getSession(id);
  if (row == null) {
    return errorResult('Session $id not found.', extra: const {
      'nextSteps': ['session_list — see valid session ids'],
    });
  }

  final cleared = note.isEmpty;
  dao.setSessionNote(id, cleared ? null : note);

  return jsonResult({
    'summary': cleared
        ? 'Cleared note on session $id.'
        : 'Set note on session $id: "${note.length > 80 ? "${note.substring(0, 80)}…" : note}".',
    'sessionId': id,
    'note': cleared ? null : note,
    'nextSteps': [
      'session_list — confirm the note shows up',
      if (!cleared)
        'session_export id:$id format:"har" outPath:"..." — share with the note as context',
    ],
  });
}
