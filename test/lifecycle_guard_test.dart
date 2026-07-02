@Timeout(Duration(seconds: 90))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// 0.9.17 regression tests for the lifecycle guard: the server must exit
/// when the MCP host goes away, instead of living forever on its timers
/// and sqlite handle (observed in the wild as multi-day orphans
/// re-parented to PID 1 after a host crash or `/mcp` reconnect).
void main() {
  Future<Process> spawnServer(Directory dataDir) => Process.start(
        Platform.resolvedExecutable,
        [
          'bin/flutter_network_mcp.dart',
          '--no-auto-discover-dtd',
          '--data-dir',
          dataDir.path,
        ],
        environment: {
          'FLUTTER_NETWORK_MCP_NO_UPDATE_CHECK': 'true',
          'FLUTTER_NETWORK_MCP_NO_JIT_NUDGE': 'true',
          'FLUTTER_NETWORK_MCP_NO_USAGE': 'true',
          'FLUTTER_NETWORK_MCP_NO_TELEMETRY': 'true',
        },
      );

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fnmcp_lifecycle_');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {/* best effort */}
  });

  test('exits promptly when the host closes stdin', () async {
    final proc = await spawnServer(tmp);
    final stderrLines = <String>[];
    final sub = proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(stderrLines.add);

    // Give the JIT snapshot time to boot, then simulate host death.
    await Future<void>.delayed(const Duration(seconds: 3));
    await proc.stdin.close();

    final exitCode = await proc.exitCode.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        proc.kill(ProcessSignal.sigkill);
        fail(
          'server still alive 20s after stdin EOF — lifecycle guard broken '
          '(this is the orphaned-process bug)',
        );
      },
    );

    expect(exitCode, 0);
    await sub.cancel();
    expect(
      stderrLines.join('\n'),
      contains('shutting down'),
      reason: 'shutdown should announce itself on stderr',
    );
  });

  test('exits promptly on SIGTERM', () async {
    final proc = await spawnServer(tmp);
    await Future<void>.delayed(const Duration(seconds: 3));
    proc.kill(ProcessSignal.sigterm);

    final exitCode = await proc.exitCode.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        proc.kill(ProcessSignal.sigkill);
        fail('server still alive 20s after SIGTERM — signal guard broken');
      },
    );
    expect(exitCode, 0);
  });
}
