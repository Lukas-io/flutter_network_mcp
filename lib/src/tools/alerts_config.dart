import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../alerts/alert_rules.dart';
import 'error_kind.dart';
import 'result.dart';

// F13: sourced from the rule engine itself so schema/toggles/count cannot
// diverge from the real rule set.
const _ruleKeys = AlertRules.ruleKeys;

final alertsConfigTool = Tool(
  name: 'alerts_config',
  description:
      'Read or update alert rules. No args (or get:true) reads; '
      'set:{slowThresholdMs?, rules?:{rule_key:bool}} mutates; invalid '
      'values are skipped and listed in rejected. Applies immediately; '
      'per-process, resets on restart.',
  inputSchema: Schema.object(
    properties: {
      'get': Schema.bool(description: 'True (default when `set` not given) to read current config.'),
      'set': Schema.object(
        description: 'Settings to update. Missing fields are left unchanged.',
        properties: {
          'slowThresholdMs': Schema.int(
            description: 'http_slow trigger threshold in ms (>0).',
          ),
          'retentionDays': Schema.int(
            description:
                'Auto-expire alerts from non-attached sessions older than '
                'this many days (keeps the pending banner recent). 0 = keep '
                'forever. Env default FLUTTER_NETWORK_MCP_ALERT_RETENTION_DAYS '
                '(14). Applies to the next hourly sweep; per-process.',
          ),
          'rules': Schema.object(
            description: 'Per-rule enable flags. Omitted rules keep their current state.',
            properties: {
              for (final key in AlertRules.ruleKeys) key: Schema.bool(),
            },
          ),
        },
      ),
    },
  ),
);

FutureOr<CallToolResult> alertsConfig(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final rawSet = args['set'];
  if (rawSet != null && rawSet is! Map) {
    return errorResult(
      'alerts_config: `set` must be an object, got ${rawSet.runtimeType}.',
      kind: ErrorKind.badArgument,
      extra: const {
        'nextSteps': [
          'alerts_config set:{slowThresholdMs:5000, rules:{http_4xx:false}}',
          'alerts_config with no args to read the current config',
        ],
      },
    );
  }
  final patch = rawSet == null
      ? null
      : validateAlertsConfigPatch(Map<String, Object?>.from(rawSet as Map));
  if (patch != null && patch.applied.isEmpty && patch.rejected.isNotEmpty) {
    return errorResult(
      'alerts_config: nothing applied; every value in `set` was rejected.',
      kind: ErrorKind.badArgument,
      extra: {
        'rejected': patch.rejected,
        'nextSteps': const [
          'alerts_config with no args to read the current config',
          'Re-call with the corrected values listed in rejected[].reason',
        ],
      },
    );
  }
  if (patch != null && patch.applied.isNotEmpty) {
    AlertRules.instance.applyConfig(
      slowThresholdMs: patch.slowThresholdMs,
      retentionDays: patch.retentionDays,
      rules: patch.rules,
    );
  }
  final mutated = patch != null && patch.applied.isNotEmpty;

  final config = AlertRules.instance.toJson();
  final rules = (config['rules'] as Map?) ?? const {};
  final enabledKeys = _ruleKeys.where((k) => rules[k] == true).toList();
  final disabledKeys = _ruleKeys.where((k) => rules[k] == false).toList();
  final slow = config['slowThresholdMs'];
  final retention = config['retentionDays'] as int? ?? 0;
  final retentionDesc = retention > 0 ? '${retention}d' : 'off';

  final rejected = patch?.rejected ?? const <Map<String, Object?>>[];
  final summary = mutated
      ? 'Updated alert config: slowThresholdMs=$slow, retention=$retentionDesc, '
          'enabled=[${enabledKeys.join(", ")}]'
          '${disabledKeys.isNotEmpty ? ", disabled=[${disabledKeys.join(", ")}]" : ""}.'
          '${rejected.isNotEmpty ? " Rejected ${rejected.length} value(s): ${rejected.map((r) => r['field']).join(", ")}." : ""}'
      : 'Alert config: slowThresholdMs=$slow, retention=$retentionDesc, '
          '${enabledKeys.length}/${_ruleKeys.length} rule(s) enabled.';

  final warnings = <String>[
    for (final r in rejected) 'Ignored ${r['field']}: ${r['reason']}.',
  ];
  if (enabledKeys.isEmpty) {
    warnings.add(
      'All rules disabled — the alerts pipeline will surface nothing. Re-enable at least one rule to use alerts_drain.',
    );
  }
  if ((slow as int?) != null && (slow as int) < 500) {
    warnings.add('slowThresholdMs is very low ($slow ms) — alerts may fire on routine traffic.');
  }

  final nextSteps = <String>[];
  if (mutated) {
    nextSteps.add('alerts_drain — see what fires under the new config');
    nextSteps.add('alerts_clear — wipe alerts that predate this rule change');
  } else {
    nextSteps.add('alerts_config set:{...} — update thresholds or toggle rules');
    nextSteps.add('alert_patterns action:list — see custom regex patterns');
  }

  return jsonResult({
    'summary': summary,
    'mutated': mutated,
    if (patch != null) 'applied': patch.applied,
    if (rejected.isNotEmpty) 'rejected': rejected,
    'config': config,
    if (warnings.isNotEmpty) 'warnings': warnings,
    'nextSteps': nextSteps,
  });
}

typedef AlertsConfigPatch = ({
  int? slowThresholdMs,
  int? retentionDays,
  Map<String, bool>? rules,
  List<String> applied,
  List<Map<String, Object?>> rejected,
});

AlertsConfigPatch validateAlertsConfigPatch(Map<String, Object?> set) {
  int? slow;
  int? retention;
  Map<String, bool>? rules;
  final applied = <String>[];
  final rejected = <Map<String, Object?>>[];
  void reject(String field, Object? value, String reason) =>
      rejected.add({'field': field, 'value': value, 'reason': reason});

  for (final entry in set.entries) {
    final value = entry.value;
    switch (entry.key) {
      case 'slowThresholdMs':
        if (value is int && value > 0) {
          slow = value;
          applied.add('slowThresholdMs');
        } else {
          reject('slowThresholdMs', value, 'must be an integer > 0');
        }
      case 'retentionDays':
        if (value is int && value >= 0) {
          retention = value;
          applied.add('retentionDays');
        } else {
          reject('retentionDays', value, 'must be an integer >= 0');
        }
      case 'rules':
        if (value is! Map) {
          reject('rules', value, 'must be an object of rule_key: bool');
          continue;
        }
        for (final rule in value.entries) {
          final field = 'rules.${rule.key}';
          if (!_ruleKeys.contains(rule.key)) {
            reject(field, rule.value,
                'unknown rule; valid: ${_ruleKeys.join(", ")}');
          } else if (rule.value is! bool) {
            reject(field, rule.value, 'must be true or false');
          } else {
            (rules ??= {})[rule.key as String] = rule.value as bool;
            applied.add(field);
          }
        }
      default:
        reject(entry.key, value,
            'unknown setting; valid: slowThresholdMs, retentionDays, rules');
    }
  }
  return (
    slowThresholdMs: slow,
    retentionDays: retention,
    rules: rules,
    applied: applied,
    rejected: rejected,
  );
}
