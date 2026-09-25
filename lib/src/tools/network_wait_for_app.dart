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

/// How often a waiting call reports progress to a client that asked for it.
const Duration kWaitProgressEvery = Duration(seconds: 15);

/// Polls DTD about once a second (cache invalidated each time so a newly
/// registered app is seen) until an unambiguous app attaches or [timeoutMs]
/// passes. Deadline-exempt (see kUnboundedTools) so the wait is not cut short.
/// When the request carries a progress token, [notifyProgress] receives the current phase every [progressEvery].
FutureOr<CallToolResult> networkWaitForApp(
  CallToolRequest request,
  String? defaultDtdUri, {
  void Function(ProgressNotification)? notifyProgress,
  Duration progressEvery = kWaitProgressEvery,
}) async {
  final args = request.arguments ?? const <String, Object?>{};
  final rawTimeout = (args['timeoutMs'] as int?) ?? 30000;
  final timeoutMs = rawTimeout.clamp(1000, 300000);
  final needle = args['appNameContains'] as String?;

  final start = DateTime.now();
  final deadline = start.add(Duration(milliseconds: timeoutMs));
  int waited() => DateTime.now().difference(start).inMilliseconds;
  var polls = 0;
  Map<String, Object?>? last;
  final waiting = needle == null
      ? 'waiting for an app to register with DTD'
      : 'waiting for an app named like "$needle" to register with DTD';
  var phase = waiting;
  final token = request.meta?.progressToken;
  final ticker = token == null || notifyProgress == null
      ? null
      : Timer.periodic(progressEvery, (_) {
          final secs = waited() ~/ 1000;
          final lastError = last?['error'];
          notifyProgress(ProgressNotification(
            progressToken: token,
            progress: waited(),
            total: timeoutMs,
            message: '$phase: ${secs}s of ${timeoutMs ~/ 1000}s, $polls poll(s)'
                '${lastError != null ? '. Last attempt: $lastError' : ''}',
          ));
        });
  try {
    while (true) {
      polls++;
      DtdProbe.invalidateCache();
      phase = 'probing DTD and attaching';
      final result = needle == null
          ? await _attachSoleApp(defaultDtdUri)
          : await performAttach(
              appNameContains: needle,
              defaultDtdUri: defaultDtdUri,
            );
      if (result['attached'] == true) {
        closeStaleViewAfterAttach(result);
        return jsonResult({...result, 'waitedMs': waited(), 'polls': polls});
      }
      // Several matching apps or a full session table: waiting cannot change it.
      if (result['retryable'] == false) {
        return errorResult(
          '${result['error']}',
          kind: ErrorKind.badArgument,
          extra: {
            ...result..remove('error')..remove('retryable'),
            'waitedMs': waited(),
            'polls': polls,
          },
        );
      }
      last = result;
      phase = waiting;
      if (DateTime.now().add(const Duration(seconds: 1)).isAfter(deadline)) break;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  } finally {
    ticker?.cancel();
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

/// Without a name to match, looks across every running DTD (not only the startup default) and attaches when exactly one app is up.
Future<Map<String, Object?>> _attachSoleApp(String? defaultDtdUri) async {
  final listings = await DtdProbe.probeAll();
  final apps = [
    for (final l in listings)
      for (final a in l.apps) (name: a.name, uri: a.uri),
  ];
  if (apps.isEmpty) {
    return {'error': 'No app has registered with any running DTD yet.'};
  }
  if (apps.length > 1) {
    return {
      'error': '${apps.length} apps are running; pass appNameContains to pick one.',
      'retryable': false,
      'apps': [
        for (final a in apps) {'name': a.name, 'uri': a.uri},
      ],
      'nextSteps': [
        for (final a in apps)
          'network_wait_for_app appNameContains:"${a.name ?? a.uri}"',
      ],
    };
  }
  return performAttach(
    vmServiceUri: apps.single.uri,
    defaultDtdUri: defaultDtdUri,
  );
}
