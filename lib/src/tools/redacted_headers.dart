import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../storage/captures_db.dart';
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
      'project-specific headers (e.g. X-Tenant-Key, X-Internal-Auth). Names '
      'are matched case-insensitively. Actions: list (default), add, remove.',
  inputSchema: Schema.object(
    properties: {
      'action': Schema.string(description: 'list | add | remove.'),
      'name': Schema.string(description: 'Header name (required for add/remove).'),
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
        return jsonResult({
          'builtins': _builtins,
          'extras': [
            for (final r in extras)
              {
                'name': r['name'],
                'addedMs': r['added_at'],
                'reason': r['reason'],
              },
          ],
          'total': _builtins.length + extras.length,
        });
      case 'add':
        if (name == null || name.isEmpty) {
          return errorResult('`name` is required for action=add.');
        }
        final isNew = dao.addRedactedHeader(name, reason: reason);
        return jsonResult({'action': 'add', 'name': name.toLowerCase(), 'inserted': isNew});
      case 'remove':
        if (name == null || name.isEmpty) {
          return errorResult('`name` is required for action=remove.');
        }
        if (_builtins.contains(name.toLowerCase())) {
          return errorResult(
            '`${name.toLowerCase()}` is a built-in default and cannot be removed.',
          );
        }
        final removed = dao.removeRedactedHeader(name);
        return jsonResult({'action': 'remove', 'name': name.toLowerCase(), 'removed': removed});
      default:
        return errorResult('`action` must be list, add, or remove.');
    }
  } catch (e) {
    return errorResult('redacted_headers failed: $e');
  }
}
