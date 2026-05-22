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
      'signals like "\\[OrderService\\].*fail" or "websocket: dropping '
      'frame". Patterns are persisted in the DB and hydrated on server start.',
  inputSchema: Schema.object(
    properties: {
      'action': Schema.string(description: '"list" (default) | "add" | "remove".'),
      'kind': Schema.string(
        description: 'Alert kind label (required for add). Free text; surfaces in alerts_drain.kind.',
      ),
      'regex': Schema.string(
        description: 'Dart RegExp source (multiLine). Required for add. Validated at compile time.',
      ),
      'severity': Schema.string(
        description: '"info" | "warning" | "error" | "critical". Required for add.',
      ),
      'label': Schema.string(
        description: 'Optional alert title; defaults to the first matching log line.',
      ),
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
          'action': 'list',
          'summary': rows.isEmpty
              ? 'No custom alert patterns registered.'
              : '${rows.length} custom alert pattern(s) registered.',
          'count': rows.length,
          'patterns': [
            for (final r in rows)
              {
                'id': r['id'],
                'kind': r['kind'],
                'regex': r['regex'],
                'severity': r['severity'],
                if (r['label'] != null) 'label': r['label'],
                'addedMs': r['added_at'],
              },
          ],
          'nextSteps': [
            if (rows.isEmpty)
              'alert_patterns action:"add" kind:"..." regex:"..." severity:"warning" — register your first pattern'
            else
              'alerts_drain — see which patterns are firing',
            'alerts_config — tune built-in rules alongside',
          ],
        });
      case 'add':
        final kind = args['kind'] as String?;
        final regex = args['regex'] as String?;
        final severity = args['severity'] as String?;
        final label = args['label'] as String?;
        if (kind == null || kind.isEmpty) {
          return errorResult('`kind` is required for action=add.', extra: const {
            'nextSteps': ['Retry with kind:"<your-label>" (free text, e.g. "order_fail")'],
          });
        }
        if (regex == null || regex.isEmpty) {
          return errorResult('`regex` is required for action=add.', extra: const {
            'nextSteps': ['Retry with regex:"<Dart RegExp source>"'],
          });
        }
        if (severity == null || severity.isEmpty) {
          return errorResult('`severity` is required for action=add.', extra: const {
            'nextSteps': ['Retry with severity:"warning" (or info | error | critical)'],
          });
        }
        final id = dao.addAlertPattern(
          kind: kind,
          regex: regex,
          severity: severity,
          label: label,
        );
        _refreshDetector(dao);

        final warnings = <String>[];
        if (regex == '.*' || regex == '.+') {
          warnings.add('Pattern `$regex` matches every log line — the alert queue will flood. Consider narrowing.');
        }

        return jsonResult({
          'action': 'add',
          'summary': 'Registered alert pattern #$id (kind=$kind, severity=$severity).',
          'id': id,
          'kind': kind,
          'severity': severity,
          if (warnings.isNotEmpty) 'warnings': warnings,
          'nextSteps': const [
            'alerts_drain — wait for matching log records, then drain to confirm fires',
            'alert_patterns action:"list" — verify registration',
            'alert_patterns action:"remove" id:<id> — undo if it misfires',
          ],
        });
      case 'remove':
        final id = args['id'] as int?;
        if (id == null) {
          return errorResult('`id` is required for action=remove.', extra: const {
            'nextSteps': ['alert_patterns action:"list" — find the id to remove'],
          });
        }
        final removed = dao.removeAlertPattern(id);
        _refreshDetector(dao);
        return jsonResult({
          'action': 'remove',
          'summary': removed
              ? 'Removed alert pattern #$id.'
              : 'No alert pattern with id $id (already removed?).',
          'id': id,
          'removed': removed,
          'nextSteps': const [
            'alert_patterns action:"list" — confirm remaining patterns',
            'alerts_clear — wipe alerts already fired by the removed pattern (optional)',
          ],
        });
      default:
        return errorResult('`action` must be list, add, or remove.', extra: const {
          'nextSteps': ['Retry with action:"list" to inspect current patterns'],
        });
    }
  } on ArgumentError catch (e) {
    return errorResult('alert_patterns: ${e.message}', extra: const {
      'nextSteps': ['Verify severity is one of: info, warning, error, critical'],
    });
  } on FormatException catch (e) {
    return errorResult('Invalid regex: ${e.message}', extra: const {
      'nextSteps': ['Test your regex pattern locally before submitting'],
    });
  } catch (e) {
    return errorResult('alert_patterns failed: $e', extra: const {
      'nextSteps': ['alert_patterns action:"list" — see what is currently registered'],
    });
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
