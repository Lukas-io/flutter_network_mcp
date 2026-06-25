import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../storage/captures_db.dart';
import 'error_kind.dart';
import 'result.dart';

const _builtins = <String>[
  'authorization',
  'cookie',
  'proxy-authorization',
  'x-api-key',
  'x-auth-token',
];

final redactedHeadersTool = Tool(
  name: 'redacted_headers',
  description:
      'Manage the list of header names that network_replay redacts. The '
      'built-in set always applies (authorization, cookie, '
      'proxy-authorization, x-api-key, x-auth-token); this tool ADDS '
      'project-specific names (e.g. X-Tenant-Key). Matched case-insensitively.',
  inputSchema: Schema.object(
    properties: {
      'action': Schema.string(description: '"list" (default) | "add" | "remove".'),
      'name': Schema.string(description: 'Header name (required for add/remove). Case-insensitive.'),
      'reason': Schema.string(description: 'Optional reason (add only).'),
    },
  ),
);

FutureOr<CallToolResult> redactedHeaders(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final action = (args['action'] as String?) ?? 'list';
  final name = args['name'] as String?;
  final reason = args['reason'] as String?;
  final dao = CapturesDao();

  try {
    switch (action) {
      case 'list':
        final extras = dao.listRedactedHeaders();
        final total = _builtins.length + extras.length;
        return jsonResult({
          'action': 'list',
          'summary': '$total redacted header name(s): ${_builtins.length} built-in, ${extras.length} project-specific.',
          'builtins': _builtins,
          'extras': [
            for (final r in extras)
              {
                'name': r['name'],
                'addedMs': r['added_at'],
                if (r['reason'] != null) 'reason': r['reason'],
              },
          ],
          'total': total,
          'nextSteps': [
            if (extras.isEmpty)
              'redacted_headers action:"add" name:"X-Tenant-Key" — extend the set with project headers'
            else
              'network_replay id:<id> — try it to confirm headers are masked',
          ],
        });
      case 'add':
        if (name == null || name.isEmpty) {
          return errorResult('`name` is required for action=add.', kind: ErrorKind.badArgument, extra: const {
            'nextSteps': ['Retry with name:"<your header>" (case-insensitive)'],
          });
        }
        final lower = name.toLowerCase();
        if (_builtins.contains(lower)) {
          return jsonResult({
            'action': 'add',
            'summary': '"$lower" is already a built-in — no change needed.',
            'name': lower,
            'inserted': false,
            'warnings': const ['Built-in header names are always redacted; this add was a no-op.'],
            'nextSteps': const ['redacted_headers action:"list" — see all redacted names'],
          });
        }
        final isNew = dao.addRedactedHeader(name, reason: reason);
        return jsonResult({
          'action': 'add',
          'summary': isNew
              ? 'Added "$lower" to redacted headers. network_replay will mask it on next call.'
              : 'Updated existing entry for "$lower" (reason/timestamp refreshed).',
          'name': lower,
          'inserted': isNew,
          'nextSteps': const [
            'network_replay id:<id> — confirm the header now shows as <redacted>',
          ],
        });
      case 'remove':
        if (name == null || name.isEmpty) {
          return errorResult('`name` is required for action=remove.', kind: ErrorKind.badArgument, extra: const {
            'nextSteps': ['redacted_headers action:"list" — see what is removable'],
          });
        }
        final lower = name.toLowerCase();
        if (_builtins.contains(lower)) {
          return errorResult(
            '"$lower" is a built-in default and cannot be removed.',
            kind: ErrorKind.badArgument,
            extra: const {
              'nextSteps': [
                'Built-ins (authorization, cookie, proxy-authorization, x-api-key, x-auth-token) are always redacted by design',
                'Use network_replay redact:false to bypass redaction entirely (local debugging only)',
              ],
            },
          );
        }
        final removed = dao.removeRedactedHeader(name);
        return jsonResult({
          'action': 'remove',
          'summary': removed
              ? 'Removed "$lower" from redacted headers. network_replay will now show its value.'
              : 'No entry for "$lower" — nothing to remove.',
          'name': lower,
          'removed': removed,
          'nextSteps': const [
            'redacted_headers action:"list" — confirm removal',
          ],
        });
      default:
        return errorResult('`action` must be list, add, or remove.', kind: ErrorKind.badArgument, extra: const {
          'nextSteps': ['Retry with action:"list" to inspect current entries'],
        });
    }
  } catch (e) {
    return errorResult('redacted_headers failed: $e', kind: ErrorKind.internal, extra: const {
      'nextSteps': ['redacted_headers action:"list" — see current state'],
    });
  }
}
