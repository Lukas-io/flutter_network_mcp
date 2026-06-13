import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../storage/captures_db.dart';
import 'result.dart';

final ignoredHostsTool = Tool(
  name: 'ignored_hosts',
  description:
      'Manage the host skiplist: the capture writer drops requests whose host '
      'matches an entry (analytics, crash reporters, noisy telemetry). Exact '
      'case-insensitive match; only new captures are filtered.',
  inputSchema: Schema.object(
    properties: {
      'action': Schema.string(description: '"list" (default) | "add" | "remove".'),
      'host': Schema.string(description: 'Hostname (required for add/remove). No scheme, no port.'),
      'reason': Schema.string(description: 'Optional reason shown in list output.'),
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
          'action': 'list',
          'summary': rows.isEmpty
              ? 'No ignored hosts. The writer captures every request.'
              : '${rows.length} ignored host(s) — new captures from these hosts are skipped.',
          'count': rows.length,
          'hosts': [
            for (final r in rows)
              {
                'host': r['host'],
                'addedMs': r['added_at'],
                if (r['reason'] != null) 'reason': r['reason'],
              },
          ],
          'nextSteps': [
            if (rows.isEmpty)
              'ignored_hosts action:"add" host:"<analytics host>" — add your first filter'
            else
              'network_list — confirm noisy hosts are no longer being captured',
            'network_query sql:"SELECT host, COUNT(*) FROM http_requests GROUP BY host ORDER BY 2 DESC" — find noisy hosts to add',
          ],
        });
      case 'add':
        if (host == null || host.isEmpty) {
          return errorResult('`host` is required for action=add.', extra: const {
            'nextSteps': ['Retry with host:"<exact hostname, no scheme/port>"'],
          });
        }
        final isNew = dao.addIgnoredHost(host, reason: reason);
        Session.instance.captureWriter.refreshIgnoredHosts();

        // Quick check: how many already-captured rows reference this host?
        int existingCount = 0;
        try {
          final rows = dao.rawSelect(
            "SELECT COUNT(*) AS n FROM http_requests WHERE host = '${host.toLowerCase()}'",
          );
          if (rows.isNotEmpty) existingCount = (rows.first['n'] as int?) ?? 0;
        } catch (_) {/* best effort */}

        final warnings = <String>[];
        if (existingCount > 0) {
          warnings.add(
            'Already-captured rows for "$host" ($existingCount in history) are NOT removed. Only new captures are skipped.',
          );
        }
        return jsonResult({
          'action': 'add',
          'summary': isNew
              ? 'Added "$host" to ignored hosts. Capture writer refreshed.'
              : 'Updated existing entry for "$host" (reason/timestamp refreshed).',
          'host': host,
          'inserted': isNew,
          if (warnings.isNotEmpty) 'warnings': warnings,
          'nextSteps': const [
            'network_list — confirm new requests from this host are skipped',
            'ignored_hosts action:"list" — see current allowlist',
          ],
        });
      case 'remove':
        if (host == null || host.isEmpty) {
          return errorResult('`host` is required for action=remove.', extra: const {
            'nextSteps': ['ignored_hosts action:"list" — find the host to remove'],
          });
        }
        final removed = dao.removeIgnoredHost(host);
        Session.instance.captureWriter.refreshIgnoredHosts();
        return jsonResult({
          'action': 'remove',
          'summary': removed
              ? 'Removed "$host" from ignored hosts. New requests will be captured again.'
              : 'No entry for "$host" — nothing to remove.',
          'host': host,
          'removed': removed,
          'nextSteps': const [
            'ignored_hosts action:"list" — confirm removal',
          ],
        });
      default:
        return errorResult('`action` must be list, add, or remove.', extra: const {
          'nextSteps': ['Retry with action:"list" to inspect current entries'],
        });
    }
  } catch (e) {
    return errorResult('ignored_hosts failed: $e', extra: const {
      'nextSteps': ['ignored_hosts action:"list" — confirm current state'],
    });
  }
}
