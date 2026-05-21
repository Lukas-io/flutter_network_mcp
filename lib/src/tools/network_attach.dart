import 'dart:async';
import 'dart:io' as io;

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../storage/captures_db.dart';
import '../storage/database.dart';
import 'result.dart';

final networkAttachTool = Tool(
  name: 'network_attach',
  description:
      'Connects to a running Flutter/Dart app via DTD, enables HTTP + socket '
      'profiling, subscribes to log streams, and opens a new capture session '
      'in the persistent database. Provide `dtdUri` to use DTD discovery '
      '(auto-picks the app if exactly one is connected), or `vmServiceUri` '
      'to bypass DTD entirely. If neither arg is given and a default DTD URI '
      'was passed at startup, that is used.',
  inputSchema: Schema.object(
    properties: {
      'dtdUri': Schema.string(
        description:
            'DTD WebSocket URI, e.g. ws://127.0.0.1:61827/<token>=. Use '
            'network_status to see whether a default is configured.',
      ),
      'vmServiceUri': Schema.string(
        description:
            'VM service WebSocket URI, e.g. ws://127.0.0.1:61828/<token>=/ws. '
            'When set, DTD is skipped.',
      ),
    },
  ),
);

FutureOr<CallToolResult> networkAttach(
  CallToolRequest request,
  String? defaultDtdUri,
) async {
  final session = Session.instance;
  final args = request.arguments ?? const <String, Object?>{};
  final dtdUriArg = args['dtdUri'] as String?;
  final vmServiceUriArg = args['vmServiceUri'] as String?;

  try {
    if (session.isAttached) await session.detach();

    String resolvedVmServiceUri;
    String? appName;

    if (vmServiceUriArg != null) {
      resolvedVmServiceUri = vmServiceUriArg;
    } else {
      final dtdUri = dtdUriArg ?? defaultDtdUri;
      if (dtdUri == null) {
        return errorResult(
          'No DTD URI provided and no default configured. Pass `dtdUri` or '
          '`vmServiceUri`, or set FLUTTER_NETWORK_MCP_DTD_URI / --dtd-uri.',
        );
      }
      await session.dtd.connect(Uri.parse(dtdUri));
      final apps = await session.dtd.getConnectedApps();
      if (apps.isEmpty) {
        return errorResult('DTD is up but reports no connected apps yet.');
      }
      if (apps.length > 1) {
        return errorResult(
          'DTD has multiple apps. Pass `vmServiceUri` explicitly.',
          extra: {
            'apps': [
              for (final a in apps) {'name': a.name, 'uri': a.uri},
            ],
          },
        );
      }
      resolvedVmServiceUri = apps.single.uri;
      appName = apps.single.name;
    }

    await session.vm.connect(Uri.parse(resolvedVmServiceUri));
    final isolateId = await session.vm.pickHttpProfilingIsolate();

    final httpState = await session.vm.enableHttpLogging();
    session.httpProfilingEnabled = httpState.enabled;

    final socketEnabled = await session.vm.enableSocketProfiling();
    session.socketProfilingEnabled = socketEnabled;

    // Open the persistent DB (no-op if already open) and create a session row.
    final db = CapturesDatabase.instance;
    final dao = CapturesDao();
    final sid = dao.createSession(
      appName: appName,
      vmServiceUri: resolvedVmServiceUri,
      isolateId: isolateId,
      projectPath: io.Directory.current.path,
    );
    session.liveSessionId = sid;

    // Logs go to ring buffer AND DB (sourcing session id lazily so future
    // ramped session changes don't strand listeners).
    await session.logStream.start(
      session.vm.service,
      session.logBuffer,
      sessionIdProvider: () => session.liveSessionId,
    );

    // Start the live capture writer (HTTP + sockets).
    session.captureWriter.start(session.vm, sid);

    session.attachedAppName = appName;

    return jsonResult({
      'attached': true,
      'appName': appName,
      'vmServiceUri': resolvedVmServiceUri,
      'isolateId': isolateId,
      'httpProfilingEnabled': session.httpProfilingEnabled,
      'socketProfilingEnabled': session.socketProfilingEnabled,
      'logStreamActive': session.logStream.isActive,
      'liveSessionId': sid,
      'capturesDbPath': db.path,
    });
  } catch (e, st) {
    await session.detach();
    return errorResult('Attach failed: $e', extra: {'stackTrace': st.toString()});
  }
}
