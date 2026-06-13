import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../config/session_filters.dart';
import '../util/filters.dart';
import 'result.dart';

final sessionConfigureTool = Tool(
  name: 'session_configure',
  description:
      'Set process-wide sticky default filters that logs_tail and '
      'network_list inherit when you omit the matching arg (set levelMin / '
      'messageContains / statusMin once, then read without repeating them). '
      'An arg you pass still wins. Pass null to unset a field, clear:true to '
      'reset all, no args to view. In-memory; resets on restart.',
  inputSchema: Schema.object(
    properties: {
      'levelMin': Schema.int(description: 'Default logs_tail levelMin.'),
      'loggerContains':
          Schema.string(description: 'Default logs_tail loggerContains.'),
      'messageContains': Schema.list(
        description: 'Default logs_tail messageContains (OR-matched list).',
        items: Schema.string(),
      ),
      'source': Schema.string(
        description: 'Default logs_tail source ("logging" | "stdout" | "stderr").',
      ),
      'method': Schema.list(
        description: 'Default network_list HTTP method(s).',
        items: Schema.string(),
      ),
      'hostContains':
          Schema.string(description: 'Default network_list hostContains.'),
      'statusMin': Schema.int(description: 'Default network_list statusMin.'),
      'statusMax': Schema.int(description: 'Default network_list statusMax.'),
      'clear': Schema.bool(description: 'Reset ALL sticky defaults to none.'),
    },
  ),
);

FutureOr<CallToolResult> sessionConfigure(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final sf = SessionFilters.instance;

  // clear runs first, so `clear:true levelMin:1000` resets everything then
  // sets the one field you passed.
  if (args['clear'] == true) sf.clear();

  // Each present key sets (or, with null, unsets) that one default. Absent
  // keys are left unchanged.
  if (args.containsKey('levelMin')) sf.levelMin = args['levelMin'] as int?;
  if (args.containsKey('loggerContains')) {
    sf.loggerContains = args['loggerContains'] as String?;
  }
  if (args.containsKey('messageContains')) {
    sf.messageContains = readStringList(args['messageContains']);
  }
  if (args.containsKey('source')) sf.source = args['source'] as String?;
  if (args.containsKey('method')) sf.method = readStringList(args['method']);
  if (args.containsKey('hostContains')) {
    sf.hostContains = args['hostContains'] as String?;
  }
  if (args.containsKey('statusMin')) sf.statusMin = args['statusMin'] as int?;
  if (args.containsKey('statusMax')) sf.statusMax = args['statusMax'] as int?;

  final block = sf.toBlock();
  final summary = sf.isEmpty
      ? 'No sticky default filters set. logs_tail / network_list use only the '
          'args you pass them.'
      : 'Sticky defaults active (${block.keys.join(", ")}). logs_tail / '
          'network_list inherit these when you omit the arg; an arg you pass '
          'still wins for that call.';

  return jsonResult({
    'summary': summary,
    'defaults': block,
    'nextSteps': sf.isEmpty
        ? const [
            'session_configure levelMin:1000 messageContains:["[EventTracker]"] to default to those logs',
            'session_configure statusMin:400 to default to HTTP errors only',
          ]
        : const [
            'logs_tail now returns the filtered view without repeating args',
            'session_configure clear:true to drop all sticky defaults',
          ],
  });
}
