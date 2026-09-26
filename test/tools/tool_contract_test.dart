import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Tool names and input schemas are the public API; run with FNM_UPDATE_GOLDENS=1 to accept a deliberate change.
void main() {
  test('tool names and input schemas match the committed contract', () async {
    final dataDir = Directory.systemTemp.createTempSync('tool_contract_');
    addTearDown(() => dataDir.deleteSync(recursive: true));
    final proc = await Process.start(
      Platform.resolvedExecutable,
      ['run', 'bin/flutter_network_mcp.dart', '--no-auto-discover-dtd', '--data-dir', dataDir.path],
      environment: {
        'GLINT_NETWORK_NO_TELEMETRY': 'true',
        'GLINT_NETWORK_NO_UPDATE_CHECK': 'true',
        'GLINT_NETWORK_NO_JIT_NUDGE': 'true',
      },
    );
    addTearDown(proc.kill);
    unawaited(proc.stderr.drain<void>());
    final replies = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .where((l) => l.startsWith('{'))
        .map((l) => jsonDecode(l) as Map<String, Object?>)
        .asBroadcastStream();

    Future<Map<String, Object?>> call(int id, String method, Map<String, Object?> params) {
      proc.stdin.writeln(jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params}));
      return replies.firstWhere((m) => m['id'] == id).timeout(const Duration(seconds: 90));
    }

    await call(1, 'initialize', {
      'protocolVersion': '2024-11-05',
      'capabilities': const {},
      'clientInfo': {'name': 'contract-test', 'version': '0'},
    });
    proc.stdin.writeln(jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}));
    final list = await call(2, 'tools/list', const {});
    final tools = ((list['result'] as Map)['tools'] as List).cast<Map<String, Object?>>();
    final contract = {
      for (final t in tools..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String)))
        t['name'] as String: t['inputSchema'],
    };
    final encoded = '${const JsonEncoder.withIndent('  ').convert(contract)}\n';
    final golden = File('test/goldens/tool_contract.json');
    if (Platform.environment['FNM_UPDATE_GOLDENS'] == '1' || !golden.existsSync()) {
      golden.writeAsStringSync(encoded);
    }
    expect(encoded, golden.readAsStringSync(),
        reason: 'A tool name or input schema changed. If intended, rerun with '
            'FNM_UPDATE_GOLDENS=1 and commit test/goldens/tool_contract.json.');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
