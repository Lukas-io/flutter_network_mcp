import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../alerts/alert_rules.dart';
import 'error_kind.dart';
import 'result.dart';

const _ruleKeys = [
  'http_5xx',
  'http_4xx',
  'http_error',
  'http_slow',
  'log_keyword',
  'flutter_error',
];

final alertsConfigTool = Tool(
  name: 'alerts_config',
  description:
      'Read or update alert rules. No args (or get:true) reads; '
      'set:{slowThresholdMs?, rules?:{rule_key:bool}} mutates. Applies '
      'immediately; per-process, resets on restart.',
  inputSchema: Schema.object(
    properties: {
      'get': Schema.bool(description: 'True (default when `set` not given) to read current config.'),
      'set': Schema.object(
        description: 'Settings to update. Missing fields are left unchanged.',
        properties: {
          'slowThresholdMs': Schema.int(
            description: 'http_slow trigger threshold in ms (>0).',
          ),
          'rules': Schema.object(
            description: 'Per-rule enable flags. Omitted rules keep their current state.',
            properties: {
              'http_5xx': Schema.bool(),
              'http_4xx': Schema.bool(),
              'http_error': Schema.bool(),
              'http_slow': Schema.bool(),
              'log_keyword': Schema.bool(),
              'flutter_error': Schema.bool(),
            },
          ),
        },
      ),
    },
  ),
);

FutureOr<CallToolResult> alertsConfig(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final setArg = args['set'] as Map<String, Object?>?;
  final mutated = setArg != null;
  if (mutated) {
    try {
      AlertRules.instance.applyConfig(
        slowThresholdMs: setArg['slowThresholdMs'] as int?,
        rules: setArg['rules'] as Map<String, dynamic>?,
      );
    } catch (e) {
      return errorResult('alerts_config: $e', kind: ErrorKind.badArgument, extra: const {
        'nextSteps': [
          'alerts_config get:true — see current config',
          'Re-call with corrected values',
        ],
      });
    }
  }

  final config = AlertRules.instance.toJson();
  final rules = (config['rules'] as Map?) ?? const {};
  final enabledKeys = _ruleKeys.where((k) => rules[k] == true).toList();
  final disabledKeys = _ruleKeys.where((k) => rules[k] == false).toList();
  final slow = config['slowThresholdMs'];

  final summary = mutated
      ? 'Updated alert config: slowThresholdMs=$slow, enabled=[${enabledKeys.join(", ")}]'
          '${disabledKeys.isNotEmpty ? ", disabled=[${disabledKeys.join(", ")}]" : ""}.'
      : 'Alert config: slowThresholdMs=$slow, ${enabledKeys.length}/${_ruleKeys.length} rule(s) enabled.';

  final warnings = <String>[];
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
    'config': config,
    if (warnings.isNotEmpty) 'warnings': warnings,
    'nextSteps': nextSteps,
  });
}
