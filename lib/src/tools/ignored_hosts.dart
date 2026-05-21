import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../storage/captures_db.dart';
import 'result.dart';

final ignoredHostsTool = Tool(
  name: 'ignored_hosts',
  description:
      'Manage the host allowlist. The capture writer skips any HTTP request '
      'whose host matches an entry — useful for filtering out analytics, '
      'crash reporters, and noisy telemetry so the agent sees only the '
      'requests that matter. Actions: list (default), add, remove.',
  inputSchema: Schema.object(
    properties: {
      'action': Schema.string(description: 'list | add | remove. Default: list.'),
      'host': Schema.string(description: 'Hostname (required for add/remove).'),
      'reason': Schema.string(description: 'Optional reason (add only).'),
    },
  ),
);

FutureOr<CallToolResult> ignoredHosts(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final action = (args['action'] as String?) ?? 'list';
  final host = args['host'] as String?;
  final reason = args['reason'] as String?;
  final dao = CapturesDao();

  try {
    switch (action) {
      case 'list':
        final rows = dao.listIgnoredHosts();
        return jsonResult({
          'count': rows.length,
          'hosts': [
            for (final r in rows)
              {
                'host': r['host'],
                'addedMs': r['added_at'],
                'reason': r['reason'],
              },
          ],
        });
      case 'add':
        if (host == null || host.isEmpty) {
          return errorResult('`host` is required for action=add.');
        }
        final isNew = dao.addIgnoredHost(host, reason: reason);
        Session.instance.captureWriter.refreshIgnoredHosts();
        return jsonResult({'action': 'add', 'host': host, 'inserted': isNew});
      case 'remove':
        if (host == null || host.isEmpty) {
          return errorResult('`host` is required for action=remove.');
        }
        final removed = dao.removeIgnoredHost(host);
        Session.instance.captureWriter.refreshIgnoredHosts();
        return jsonResult({'action': 'remove', 'host': host, 'removed': removed});
      default:
        return errorResult('`action` must be list, add, or remove.');
    }
  } catch (e) {
    return errorResult('ignored_hosts failed: $e');
  }
}
