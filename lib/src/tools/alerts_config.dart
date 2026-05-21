import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../alerts/alert_rules.dart';
import 'result.dart';

final alertsConfigTool = Tool(
  name: 'alerts_config',
  description:
      'Read or update alert rule settings. Pass `get:true` (default) to read '
      'current config. Pass `set:{slowThresholdMs?, rules?:{rule_key:bool}}` '
      'to mutate. Rule keys: http_5xx, http_4xx, http_error, http_slow, '
      'log_keyword, flutter_error.',
  inputSchema: Schema.object(
    properties: {
      'get': Schema.bool(description: 'True to read current config.'),
      'set': Schema.object(
        description: 'Settings to update.',
        properties: {
          'slowThresholdMs': Schema.int(),
          'rules': Schema.object(
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
  if (setArg != null) {
    try {
      AlertRules.instance.applyConfig(
        slowThresholdMs: setArg['slowThresholdMs'] as int?,
        rules: setArg['rules'] as Map<String, dynamic>?,
      );
    } catch (e) {
      return errorResult('alerts_config: $e');
    }
  }
  return jsonResult({'config': AlertRules.instance.toJson()});
}
