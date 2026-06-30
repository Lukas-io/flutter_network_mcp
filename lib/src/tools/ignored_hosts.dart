import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../config/capture_filter.dart';
import '../state/session.dart';
import '../storage/captures_db.dart';
import 'error_kind.dart';
import 'result.dart';

final ignoredHostsTool = Tool(
  name: 'ignored_hosts',
  description:
      'Manage the capture skiplist (a denylist): the writer drops requests that '
      'match an entry (analytics, crash reporters, noisy telemetry). An entry '
      'with no "/" matches a whole host; an entry with "/" is a host/path glob '
      '(e.g. dev.example.com/socket.io/*) so you can silence one noisy path '
      'while keeping the rest of the host. Case-insensitive; only new captures '
      'are filtered. The opposite (capture ONLY matching requests) is the '
      'capture_allow tool / FLUTTER_NETWORK_MCP_CAPTURE_ALLOW env var, surfaced '
      'in the list output as captureAllowlist.',
  inputSchema: Schema.object(
    properties: {
      'action': Schema.string(description: '"list" (default) | "add" | "remove".'),
      'host': Schema.string(
        description:
            'Host or host/path glob (required for add/remove). No scheme, no '
            'port. Examples: "analytics.example.com", "dev.example.com/socket.io/*".',
      ),
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
        final allowlist = CaptureFilter.build(const {},
                allowEntries: dao.captureAllowSet())
            .allowPatterns;
        return jsonResult({
          'action': 'list',
          'summary': rows.isEmpty
              ? 'No skiplist entries. The writer captures every request${allowlist.isEmpty ? '' : ' that matches the allowlist'}.'
              : '${rows.length} skiplist entr(ies) — matching new captures are dropped.',
          'count': rows.length,
          'hosts': [
            for (final r in rows)
              {
                'host': r['host'],
                'addedMs': r['added_at'],
                if (r['reason'] != null) 'reason': r['reason'],
              },
          ],
          'captureAllowlist': {
            'active': allowlist.isNotEmpty,
            'patterns': allowlist,
            'managedBy': 'capture_allow tool (persistent) + FLUTTER_NETWORK_MCP_CAPTURE_ALLOW env',
            if (allowlist.isNotEmpty)
              'note': 'Only requests matching these patterns are captured; everything else is dropped.',
          },
          'nextSteps': [
            if (rows.isEmpty)
              'ignored_hosts action:"add" host:"dev.example.com/socket.io/*" — skip one noisy path'
            else
              'network_list — confirm noisy paths are no longer being captured',
            'network_query sql:"SELECT host, COUNT(*) FROM http_requests GROUP BY host ORDER BY 2 DESC" — find noisy hosts to add',
          ],
        });
      case 'add':
        if (host == null || host.isEmpty) {
          return errorResult('`host` is required for action=add.', kind: ErrorKind.badArgument, extra: const {
            'nextSteps': ['Retry with host:"<exact hostname, no scheme/port>"'],
          });
        }
        final isNew = dao.addIgnoredHost(host, reason: reason);
        Session.instance.captureWriter.refreshIgnoredHosts();

        int existingCount = 0;
        try {
          existingCount = dao.countRequestsForHost(host);
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
            'network_list — confirm new requests matching this pattern are skipped',
            'ignored_hosts action:"list" — see the current skiplist + allowlist',
          ],
        });
      case 'remove':
        if (host == null || host.isEmpty) {
          return errorResult('`host` is required for action=remove.', kind: ErrorKind.badArgument, extra: const {
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
        return errorResult('`action` must be list, add, or remove.', kind: ErrorKind.badArgument, extra: const {
          'nextSteps': ['Retry with action:"list" to inspect current entries'],
        });
    }
  } catch (e) {
    return errorResult('ignored_hosts failed: $e', kind: ErrorKind.internal, extra: const {
      'nextSteps': ['ignored_hosts action:"list" — confirm current state'],
    });
  }
}
