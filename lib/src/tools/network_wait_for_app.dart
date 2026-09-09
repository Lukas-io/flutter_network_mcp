import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../vm/dtd_probe.dart';
import 'error_kind.dart';
import 'network_attach.dart';
import 'result.dart';

final networkWaitForAppTool = Tool(
  name: 'network_wait_for_app',
  description:
      'Block until a Flutter app registers with DTD, then attach to it and '
      'return the attach result. Use when an app is still starting: '
      'network_status returns immediately with nothing, and the VM service '
      'auth token cannot be recovered from lsof to attach by hand. timeoutMs '
      '(default 30000, max 300000); appNameContains attaches only a matching '
      'app (recommended when several may be up). errorKind: timeout when no '
      'app attaches in time.',
  inputSchema: Schema.object(
    properties: {
      'timeoutMs': Schema.int(
        description: 'How long to wait, in ms (1000-300000). Default 30000.',
      ),
      'appNameContains': Schema.string(
        description:
            'Attach only an app whose name contains this (case-insensitive). '
            'Pass it when several apps may register at once.',
      ),
    },
  ),
);

/// Polls DTD about once a second (cache invalidated each time so a newly
/// registered app is seen) until an unambiguous app attaches or [timeoutMs]
/// passes. Deadline-exempt (see kUnboundedTools) so the wait is not cut short.
FutureOr<CallToolResult> networkWaitForApp(
  CallToolRequest request,
  String? defaultDtdUri,
) async {
  final args = request.arguments ?? const <String, Object?>{};
  final rawTimeout = (args['timeoutMs'] as int?) ?? 30000;
  final timeoutMs = rawTimeout.clamp(1000, 300000);
  final needle = args['appNameContains'] as String?;

  final start = DateTime.now();
  final deadline = start.add(Duration(milliseconds: timeoutMs));
  var polls = 0;
  Map<String, Object?>? last;
  while (true) {
    polls++;
    DtdProbe.invalidateCache();
    final result = await performAttach(
      appNameContains: needle,
      defaultDtdUri: defaultDtdUri,
    );
    if (result['attached'] == true) {
      return jsonResult({
        ...result,
        'waitedMs': DateTime.now().difference(start).inMilliseconds,
        'polls': polls,
      });
    }
    last = result;
    if (DateTime.now().add(const Duration(seconds: 1)).isAfter(deadline)) break;
    await Future<void>.delayed(const Duration(seconds: 1));
  }

  return errorResult(
    'No app attached within ${timeoutMs}ms (polled $polls time(s)).'
    '${needle != null ? ' Waited for a name containing "$needle".' : ''}',
    kind: ErrorKind.timeout,
    extra: {
      'waitedMs': DateTime.now().difference(start).inMilliseconds,
      'polls': polls,
      if (last['error'] != null) 'lastAttempt': last['error'],
      'nextSteps': [
        'launch the app, or check it is not crashing on start',
        if (needle == null)
          'if several apps may run, pass appNameContains to disambiguate',
        'network_status — see what DTD reports right now',
      ],
    },
  );
}
