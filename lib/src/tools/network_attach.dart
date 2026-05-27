import 'dart:async';
import 'dart:io' as io;

import 'package:dart_mcp/server.dart';

import '../config/capabilities.dart';
import '../state/session.dart';
import '../storage/captures_db.dart';
import 'result.dart';

final networkAttachTool = Tool(
  name: 'network_attach',
  description:
      'Open a capture session against a running Flutter/Dart app — call '
      'this after `network_status` shows the app you want under '
      '`knownApps`. Enables HTTP + socket profiling, subscribes to log '
      'streams, and creates a new row in `sessions` so everything that '
      'follows is persisted. Zero-arg works when exactly one app is '
      'reachable and a default DTD URI is set; pass `appNameContains` to '
      'disambiguate when multiple apps are visible. Re-attaching to a '
      'different target requires `force:true` so live state is never '
      'silently lost.',
  inputSchema: Schema.object(
    properties: {
      'dtdUri': Schema.string(
        description: 'DTD WebSocket URI. Overrides the default.',
      ),
      'vmServiceUri': Schema.string(
        description:
            'VM service URI. Bypasses DTD entirely; takes priority over '
            'dtdUri / appNameContains.',
      ),
      'appNameContains': Schema.string(
        description:
            'Case-insensitive substring match on the DTD app name (from '
            'network_status.knownApps[].name). Use when DTD has multiple apps.',
      ),
      'force': Schema.bool(
        description:
            'Required (true) if currently attached — otherwise the call '
            'errors so live capture state is not accidentally discarded.',
      ),
    },
  ),
);

FutureOr<CallToolResult> networkAttach(
  CallToolRequest request,
  String? defaultDtdUri,
) async {
  final args = request.arguments ?? const <String, Object?>{};
  final result = await performAttach(
    dtdUri: args['dtdUri'] as String?,
    vmServiceUri: args['vmServiceUri'] as String?,
    appNameContains: args['appNameContains'] as String?,
    force: (args['force'] as bool?) ?? false,
    defaultDtdUri: defaultDtdUri,
  );
  return jsonResult(result, isError: result['error'] != null);
}

/// Shared attach implementation. Returns a Map suitable for [jsonResult].
/// If `error` is set, the caller should mark the result as an error.
///
/// This is exported so [networkStatus] can reuse it for `attachIfOne:true`.
Future<Map<String, Object?>> performAttach({
  String? dtdUri,
  String? vmServiceUri,
  String? appNameContains,
  bool force = false,
  String? defaultDtdUri,
}) async {
  final session = Session.instance;

  if (session.isAttached && !force) {
    return {
      'error':
          'Already attached to "${session.attachedAppName ?? '(unknown app)'}" '
          '(session ${session.liveSessionId}). Pass `force:true` to detach '
          'and re-attach, or call network_detach first.',
      'currentApp': session.attachedAppName,
      'liveSessionId': session.liveSessionId,
      'nextSteps': [
        'network_detach (graceful, keeps existing session data)',
        'network_attach force:true (silently detaches first)',
      ],
    };
  }

  try {
    if (session.isAttached) await session.detach();

    String resolvedVmServiceUri;
    String? appName;

    if (vmServiceUri != null) {
      resolvedVmServiceUri = vmServiceUri;
    } else {
      final useDtd = dtdUri ?? defaultDtdUri;
      if (useDtd == null) {
        return {
          'error':
              'No DTD URI provided and no default configured. Pass '
              '`dtdUri` or `vmServiceUri`, or have the user configure '
              'a default at server startup.',
          'nextSteps': const [
            'Ask the user for the DTD URI (printed in the IDE console after `flutter run`)',
            'Update --dtd-uri in .mcp.json and have the user restart Claude Code',
          ],
        };
      }
      await session.dtd.connect(Uri.parse(useDtd));
      final apps = await session.dtd.getConnectedApps();
      if (apps.isEmpty) {
        return {
          'error': 'DTD is up but reports no connected apps yet.',
          'nextSteps': [
            'Launch a Flutter app in debug mode',
            'Re-check via network_status',
          ],
        };
      }

      // Optional substring filter on app name (case-insensitive).
      var filtered = apps;
      if (appNameContains != null && appNameContains.isNotEmpty) {
        final needle = appNameContains.toLowerCase();
        filtered = apps
            .where((a) => (a.name ?? '').toLowerCase().contains(needle))
            .toList();
        if (filtered.isEmpty) {
          return {
            'error':
                'No DTD app name contains "$appNameContains". '
                'Visible apps: ${apps.map((a) => a.name).join(', ')}.',
            'apps': [
              for (final a in apps) {'name': a.name, 'uri': a.uri},
            ],
            'nextSteps': [
              'Re-check spelling or try a different substring',
              'Call network_status to see the current app list',
            ],
          };
        }
      }

      if (filtered.length > 1) {
        return {
          'error': 'DTD has multiple matching apps; pass `appNameContains` or '
              'an explicit `vmServiceUri`.',
          'apps': [
            for (final a in filtered) {'name': a.name, 'uri': a.uri},
          ],
          'nextSteps': [
            'network_attach appNameContains:"<unique substring>"',
            'network_attach vmServiceUri:"<from apps[].uri>"',
          ],
        };
      }
      resolvedVmServiceUri = filtered.single.uri;
      appName = filtered.single.name;
    }

    await session.vm.connect(Uri.parse(resolvedVmServiceUri));
    final isolateId = await session.vm.pickHttpProfilingIsolate();

    final httpState = await session.vm.enableHttpLogging();
    session.httpProfilingEnabled = httpState.enabled;

    final caps = CapabilityConfig.instance;
    final bool socketEnabled;
    if (caps.isEnabled(Category.sockets)) {
      socketEnabled = await session.vm.enableSocketProfiling();
    } else {
      socketEnabled = false;
    }
    session.socketProfilingEnabled = socketEnabled;

    final dao = CapturesDao();
    final sid = dao.createSession(
      appName: appName,
      vmServiceUri: resolvedVmServiceUri,
      isolateId: isolateId,
      projectPath: io.Directory.current.path,
    );
    session.liveSessionId = sid;

    if (caps.isEnabled(Category.logs)) {
      await session.logStream.start(
        session.vm.service,
        session.logBuffer,
        sessionIdProvider: () => session.liveSessionId,
      );
    }

    session.captureWriter.start(session.vm, sid);

    session.attachedAppName = appName;

    // Phase 1 of multi-attach refactor: shadow this attach in the registry
    // so the Phase 3 scope resolver can route reads correctly once it
    // lands. In Phase 1 the AttachedSession references the shared
    // [Session.instance] resources; Phase 2 makes them owned per-attach.
    SessionRegistry.instance.register(
      AttachedSession(
        id: sid,
        appName: appName,
        vmServiceUri: resolvedVmServiceUri,
        isolateId: isolateId,
        vm: session.vm,
        captureWriter: session.captureWriter,
        logBuffer: session.logBuffer,
        logStream: session.logStream,
        attachedAt: DateTime.now(),
      ),
    );

    // Synthesize warnings for partial degradation.
    final warnings = <String>[];
    if (!httpState.enabled) {
      warnings.add(
        'HTTP timeline logging did not enable cleanly — captured requests may be incomplete.',
      );
    }
    if (caps.isEnabled(Category.sockets) && !socketEnabled) {
      warnings.add(
        'socket profiling unavailable on this isolate — socket_* tools will return empty.',
      );
    }
    if (caps.isEnabled(Category.logs) && !session.logStream.isActive) {
      warnings.add(
        'log stream subscription did not start — logs_tail will be empty.',
      );
    }

    // Capability-aware nextSteps for the post-attach read tools.
    final readTools = <String>[];
    if (caps.isEnabled(Category.http)) readTools.add('network_list');
    if (caps.isEnabled(Category.logs) && session.logStream.isActive) {
      readTools.add('logs_tail');
    }
    if (caps.isEnabled(Category.alerts)) readTools.add('alerts_drain');
    final secondStep = readTools.isEmpty
        ? 'Then read via the enabled tools (see network_status.capabilities)'
        : 'Then call ${readTools.join(' / ')}';

    // One-line summary the agent can echo back to the user.
    final captured = <String>[];
    if (httpState.enabled) captured.add('HTTP');
    if (socketEnabled) captured.add('sockets');
    if (session.logStream.isActive) captured.add('logs');
    final what =
        captured.isEmpty ? 'no streams (degraded)' : captured.join('+');
    final summary =
        'Attached to ${appName ?? "app"} — capturing $what into session $sid.';

    return {
      'attached': true,
      'summary': summary,
      'appName': appName,
      'vmServiceUri': resolvedVmServiceUri,
      'isolateId': isolateId,
      'liveSessionId': sid,
      'socketProfilingEnabled': socketEnabled,
      if (warnings.isNotEmpty) 'warnings': warnings,
      'nextSteps': [
        'Drive the app to generate traffic',
        secondStep,
      ],
    };
  } catch (e, st) {
    // Stack trace goes to stderr only — never into the LLM context.
    io.stderr.writeln('network_attach failed: $e\n$st');
    await session.detach();
    final msg = e.toString();
    final isZombie = msg.contains('did not respond to getVersion');
    return {
      'error': 'Attach failed: $msg',
      'nextSteps': isZombie
          ? const [
              'Restart the Flutter app to spawn a fresh DTD/DDS',
              'Re-check via network_status (new DTD URI will auto-populate knownApps)',
            ]
          : const [
              'Call network_status to confirm the DTD URI is still valid',
            ],
    };
  }
}
