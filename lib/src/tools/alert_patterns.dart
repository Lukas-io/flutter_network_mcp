import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../alerts/alert_rules.dart';
import '../storage/captures_db.dart';
import 'result.dart';

final alertPatternsTool = Tool(
  name: 'alert_patterns',
  description:
      'Manage custom alert regex patterns. The detector evaluates these '
      'against every captured log message (in addition to the built-in '
      'flutter_error and log_keyword rules). Useful for project-specific '
      'signals like "[OrderService].*fail" or "websocket: dropping frame". '
      'Actions: list (default), add, remove.',
  inputSchema: Schema.object(
    properties: {
      'action': Schema.string(description: 'list | add | remove.'),
      'kind': Schema.string(
        description: 'Alert kind label (required for add). Free text.',
      ),
      'regex': Schema.string(
        description: 'Dart regular expression (multiLine). Required for add.',
      ),
      'severity': Schema.string(
        description: 'info | warning | error | critical. Required for add.',
      ),
      'label': Schema.string(description: 'Optional alert title; defaults to the first matching line.'),
      'id': Schema.int(description: 'Pattern id (required for remove).'),
    },
  ),
);

FutureOr<CallToolResult> alertPatterns(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final action = (args['action'] as String?) ?? 'list';
  final dao = CapturesDao();

  try {
    switch (action) {
      case 'list':
        final rows = dao.listAlertPatterns();
        return jsonResult({
          'count': rows.length,
          'patterns': [
            for (final r in rows)
              {
                'id': r['id'],
                'kind': r['kind'],
                'regex': r['regex'],
                'severity': r['severity'],
                'label': r['label'],
                'addedMs': r['added_at'],
              },
          ],
        });
      case 'add':
        final kind = args['kind'] as String?;
        final regex = args['regex'] as String?;
        final severity = args['severity'] as String?;
        final label = args['label'] as String?;
        if (kind == null || kind.isEmpty) {
          return errorResult('`kind` is required for action=add.');
        }
        if (regex == null || regex.isEmpty) {
          return errorResult('`regex` is required for action=add.');
        }
        if (severity == null || severity.isEmpty) {
          return errorResult('`severity` is required for action=add.');
        }
        final id = dao.addAlertPattern(
          kind: kind,
          regex: regex,
          severity: severity,
          label: label,
        );
        _refreshDetector(dao);
        return jsonResult({'action': 'add', 'id': id, 'kind': kind});
      case 'remove':
        final id = args['id'] as int?;
        if (id == null) {
          return errorResult('`id` is required for action=remove.');
        }
        final removed = dao.removeAlertPattern(id);
        _refreshDetector(dao);
        return jsonResult({'action': 'remove', 'id': id, 'removed': removed});
      default:
        return errorResult('`action` must be list, add, or remove.');
    }
  } on ArgumentError catch (e) {
    return errorResult('alert_patterns: ${e.message}');
  } on FormatException catch (e) {
    return errorResult('Invalid regex: ${e.message}');
  } catch (e) {
    return errorResult('alert_patterns failed: $e');
  }
}

void _refreshDetector(CapturesDao dao) {
  final rows = dao.listAlertPatterns();
  AlertRules.instance.customPatterns = [
    for (final r in rows)
      CustomPattern(
        id: r['id'] as int,
        kind: r['kind'] as String,
        regex: RegExp(r['regex'] as String, multiLine: true),
        severity: r['severity'] as String,
        label: r['label'] as String?,
      ),
  ];
}

/// Loads custom patterns from DB into the AlertRules singleton. Called from
/// bin/main.dart at startup so existing patterns apply immediately.
void loadCustomPatternsFromDb() {
  final rows = CapturesDao().listAlertPatterns();
  AlertRules.instance.customPatterns = [
    for (final r in rows)
      CustomPattern(
        id: r['id'] as int,
        kind: r['kind'] as String,
        regex: RegExp(r['regex'] as String, multiLine: true),
        severity: r['severity'] as String,
        label: r['label'] as String?,
      ),
  ];
}
