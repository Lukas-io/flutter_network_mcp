import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../storage/captures_db.dart';
import 'error_kind.dart';
import 'result.dart';

final captureAllowTool = Tool(
  name: 'capture_allow',
  description:
      'Manage the capture ALLOWLIST (the opposite of ignored_hosts). When it '
      'has any entry, ONLY requests matching a host or host/path glob are '
      'captured and everything else is dropped at capture time — for focused '
      'debugging ("just /stock/*"). Mid-session equivalent of the '
      'FLUTTER_NETWORK_MCP_CAPTURE_ALLOW env var; both unions apply, and the '
      'ignored_hosts denylist still wins inside the allowed set. Only new '
      'captures are affected.',
  inputSchema: Schema.object(
    properties: {
      'action': Schema.string(description: '"list" (default) | "add" | "remove".'),
      'pattern': Schema.string(
        description:
            'Host or host/path glob (required for add/remove). No scheme, no '
            'port. Examples: "api.example.com", "api.example.com/stock/*".',
      ),
      'reason': Schema.string(description: 'Optional reason shown in list output.'),
    },
  ),
);

FutureOr<CallToolResult> captureAllow(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final action = (args['action'] as String?) ?? 'list';
  final pattern = args['pattern'] as String?;
  final reason = args['reason'] as String?;
  final dao = CapturesDao();

  try {
    switch (action) {
      case 'list':
        final rows = dao.listCaptureAllow();
        return jsonResult({
          'action': 'list',
          'summary': rows.isEmpty
              ? 'Allowlist empty — every request is captured (unless ignored_hosts skips it).'
              : '${rows.length} allowlist pattern(s) — ONLY matching requests are captured; everything else is dropped.',
          'count': rows.length,
          'patterns': [
            for (final r in rows)
              {
                'pattern': r['pattern'],
                'addedMs': r['added_at'],
                if (r['reason'] != null) 'reason': r['reason'],
              },
          ],
          'envNote': 'FLUTTER_NETWORK_MCP_CAPTURE_ALLOW adds startup patterns too; both unions apply.',
          'nextSteps': [
            if (rows.isEmpty)
              'capture_allow action:"add" pattern:"api.example.com/stock/*" — capture only this'
            else ...[
              'network_list — confirm only allowed requests are being captured',
              'capture_allow action:"remove" pattern:"<pattern>" — widen capture again',
            ],
          ],
        });
      case 'add':
        if (pattern == null || pattern.isEmpty) {
          return errorResult('`pattern` is required for action=add.',
              kind: ErrorKind.badArgument,
              extra: const {
                'nextSteps': ['Retry with pattern:"<host or host/path glob>"'],
              });
        }
        final isNew = dao.addCaptureAllow(pattern, reason: reason);
        Session.instance.captureWriter.refreshIgnoredHosts();
        return jsonResult({
          'action': 'add',
          'summary': isNew
              ? 'Added "$pattern" to the capture allowlist. From now ONLY matching requests are captured.'
              : 'Updated existing allowlist entry for "$pattern".',
          'pattern': pattern,
          'inserted': isNew,
          'warnings': const [
            'The allowlist is now active: requests that do NOT match any allow pattern are dropped at capture time. Already-captured rows are unaffected.',
          ],
          'nextSteps': const [
            'network_list — confirm only allowed requests appear',
            'capture_allow action:"list" — see all allow patterns',
          ],
        });
      case 'remove':
        if (pattern == null || pattern.isEmpty) {
          return errorResult('`pattern` is required for action=remove.',
              kind: ErrorKind.badArgument,
              extra: const {
                'nextSteps': ['capture_allow action:"list" — find the pattern to remove'],
              });
        }
        final removed = dao.removeCaptureAllow(pattern);
        Session.instance.captureWriter.refreshIgnoredHosts();
        return jsonResult({
          'action': 'remove',
          'summary': removed
              ? 'Removed "$pattern" from the allowlist. If the allowlist is now empty, all requests are captured again.'
              : 'No allowlist entry for "$pattern" — nothing to remove.',
          'pattern': pattern,
          'removed': removed,
          'nextSteps': const [
            'capture_allow action:"list" — confirm the remaining allowlist',
          ],
        });
      default:
        return errorResult('`action` must be list, add, or remove.',
            kind: ErrorKind.badArgument,
            extra: const {
              'nextSteps': ['Retry with action:"list" to inspect current entries'],
            });
    }
  } catch (e) {
    return errorResult('capture_allow failed: $e',
        kind: ErrorKind.internal,
        extra: const {
          'nextSteps': ['capture_allow action:"list" — confirm current state'],
        });
  }
}
