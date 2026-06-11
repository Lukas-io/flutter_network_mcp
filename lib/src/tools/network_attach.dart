import 'dart:async';
import 'dart:io' as io;

import 'package:dart_mcp/server.dart';

import '../alerts/anomaly_detector.dart';
import '../config/auto_attach_config.dart';
import '../config/capabilities.dart';
import '../state/continuation.dart';
import '../state/log_buffer.dart';
import '../state/session.dart';
import '../storage/capture_writer.dart';
import '../storage/captures_db.dart';
import '../vm/dtd_probe.dart';
import '../vm/log_stream.dart';
import '../vm/vm_client.dart';
import 'result.dart';

/// One connected app flattened out of a [DtdProbe] listing, tagged with the
/// DTD that owns it. Used to resolve `appNameContains` across every DTD.
typedef DtdAppCandidate = ({String? name, String uri, Uri dtdUri});

/// Returns every [apps] entry whose name contains [needle] (case-insensitive).
/// Pulled out of [networkAttach] so the cross-DTD resolution that fixes issue
/// #14 can be unit-tested without live DTD infrastructure.
List<DtdAppCandidate> matchAppsAcrossDtds(
  List<DtdAppCandidate> apps,
  String needle,
) {
  final n = needle.toLowerCase();
  return [
    for (final a in apps)
      if ((a.name ?? '').toLowerCase().contains(n)) a,
  ];
}

final networkAttachTool = Tool(
  name: 'network_attach',
  description:
      'Open a capture session against a running Flutter/Dart app — call '
      'this after `network_status` shows the app you want under '
      '`knownApps`. Enables HTTP + socket profiling, subscribes to log '
      'streams, and creates a new row in `sessions` so everything that '
      'follows is persisted. **Multi-attach (0.6.0):** multiple apps can '
      'be attached concurrently — each gets its own VM connection + '
      'capture writer + log buffer. Re-attaching to the SAME app '
      '(matched by vmServiceUri) is blocked; attach to a different one '
      'is allowed up to FLUTTER_NETWORK_MCP_MAX_ATTACH (default 4). The '
      'response carries `scope:{sessionId, appName}` — use that sessionId '
      'to route subsequent read tools.',
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
      'logBufferSize': Schema.int(
        description:
            'Optional per-session log ring-buffer capacity (50–10000). '
            'Overrides FLUTTER_NETWORK_MCP_LOG_BUFFER for THIS session only; '
            'bump it for chatty apps whose logs rotate out before you read '
            'them. Omit to use the env / default (500).',
      ),
    },
  ),
);

/// Reads `FLUTTER_NETWORK_MCP_MAX_ATTACH` env var (1–32). Default 4.
int _maxAttachFromEnv() {
  final raw = io.Platform.environment['FLUTTER_NETWORK_MCP_MAX_ATTACH'];
  final parsed = raw == null ? null : int.tryParse(raw);
  if (parsed == null) return 4;
  if (parsed < 1) return 1;
  if (parsed > 32) return 32;
  return parsed;
}

FutureOr<CallToolResult> networkAttach(
  CallToolRequest request,
  String? defaultDtdUri,
) async {
  final args = request.arguments ?? const <String, Object?>{};
  final result = await performAttach(
    dtdUri: args['dtdUri'] as String?,
    vmServiceUri: args['vmServiceUri'] as String?,
    appNameContains: args['appNameContains'] as String?,
    logBufferSize: args['logBufferSize'] as int?,
    defaultDtdUri: defaultDtdUri,
  );
  return jsonResult(result, isError: result['error'] != null);
}

/// Shared attach implementation. Returns a Map suitable for [jsonResult].
/// If `error` is set, the caller should mark the result as an error.
///
/// **Multi-attach (Phase 5):** the old "any attach blocks attach" rule +
/// force:true escape hatch is replaced by a per-vmServiceUri duplicate
/// guard. Multiple distinct apps can attach concurrently up to
/// FLUTTER_NETWORK_MCP_MAX_ATTACH (default 4).
///
/// Exported so [networkStatus] can reuse it for `attachIfOne:true`.
Future<Map<String, Object?>> performAttach({
  String? dtdUri,
  String? vmServiceUri,
  String? appNameContains,
  int? logBufferSize,
  String? defaultDtdUri,
}) async {
  final session = Session.instance;
  final registry = SessionRegistry.instance;

  // Cap check first — cheap and rejects without any IO.
  final maxAttach = _maxAttachFromEnv();
  if (registry.attachedCount >= maxAttach) {
    return {
      'error':
          'Reached max attached sessions ($maxAttach). Detach one first or '
          'raise FLUTTER_NETWORK_MCP_MAX_ATTACH.',
      'attached': [
        for (final a in registry.attached.values)
          {'sessionId': a.id, 'appName': a.appName},
      ],
      'maxAttach': maxAttach,
      'nextSteps': [
        for (final a in registry.attached.values)
          'network_detach sessionId:${a.id}  // ${a.appName ?? "(no name)"}',
        'network_detach all:true — drop everything',
      ],
    };
  }

  // Per-attach resources are constructed locally and only become visible
  // to other tools after the AttachedSession is registered. If anything
  // fails mid-setup, the catch block tears them down directly so nothing
  // leaks into the registry.
  VmClient? localVm;
  CaptureWriter? localCaptureWriter;
  LogStreamSubscriber? localLogStream;
  bool dtdWasConnectedBefore = registry.dtd.isConnected;

  try {
    String resolvedVmServiceUri;
    String? appName;

    if (vmServiceUri != null) {
      resolvedVmServiceUri = vmServiceUri;
    } else if (appNameContains != null &&
        appNameContains.isNotEmpty &&
        dtdUri == null) {
      // #14: network_status.knownApps aggregates apps across EVERY discovered
      // DTD (each `flutter run` spawns its own), but a single-DTD
      // getConnectedApps() only sees apps under the default DTD. Resolving
      // appNameContains against just the default DTD made attach fail for an
      // app that was clearly listed in knownApps but owned by another DTD.
      // Match across all DTDs so attach agrees with what network_status shows.
      final listings = await DtdProbe.probeAll();
      final apps = <DtdAppCandidate>[
        for (final l in listings)
          for (final a in l.apps)
            (name: a.name, uri: a.uri, dtdUri: l.dtdUri),
      ];
      final allNames = [for (final a in apps) a.name ?? '(unnamed)'];
      final matches = matchAppsAcrossDtds(apps, appNameContains);
      if (matches.isEmpty) {
        return {
          'error': allNames.isEmpty
              ? 'No apps are connected to any running DTD. Is a Flutter app '
                  'running in debug mode?'
              : 'No app name contains "$appNameContains" on any running DTD. '
                  'Visible apps: ${allNames.join(', ')}.',
          'apps': [
            for (final a in apps)
              {'name': a.name, 'uri': a.uri, 'dtdUri': a.dtdUri.toString()},
          ],
          'nextSteps': const [
            'network_status to see the current knownApps list across all DTDs',
            'Re-check the appNameContains substring',
            'Pass an explicit vmServiceUri from knownApps[].uri',
          ],
        };
      }
      if (matches.length > 1) {
        return {
          'error': 'Multiple apps across DTDs match "$appNameContains"; pass a '
              'more specific substring or an explicit `vmServiceUri`.',
          'apps': [
            for (final m in matches)
              {'name': m.name, 'uri': m.uri, 'dtdUri': m.dtdUri.toString()},
          ],
          'nextSteps': const [
            'network_attach appNameContains:"<unique substring>"',
            'network_attach vmServiceUri:"<from apps[].uri>"',
          ],
        };
      }
      final match = matches.single;
      resolvedVmServiceUri = match.uri;
      appName = match.name;
      // Parity with the single-DTD path: point the session DTD at the DTD
      // that actually owns this app (best-effort; the VM attach below is
      // what the capture pipeline depends on).
      try {
        await session.dtd.connect(match.dtdUri);
      } catch (_) {/* non-fatal: capture uses the VM service URI directly */}
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

    // Per-URI duplicate guard — replaces the old force:true gate. Same
    // app can't be attached twice; different apps can coexist.
    final existing = registry.attachedByUri(resolvedVmServiceUri);
    if (existing != null) {
      return {
        'error':
            'Already attached to "${existing.appName ?? "(unknown app)"}" '
            'at $resolvedVmServiceUri (session ${existing.id}).',
        'attachedSessionId': existing.id,
        'attachedAppName': existing.appName,
        'nextSteps': [
          'network_detach sessionId:${existing.id} — drop this attachment first',
          'Read from the existing session: network_list sessionId:${existing.id}',
        ],
      };
    }

    // Per-attach resources. Each attach gets fresh instances so multiple
    // sessions can poll independently.
    final vm = localVm = VmClient();
    final captureWriter = localCaptureWriter = CaptureWriter();
    final logBuffer = LogBuffer(
      capacity: logBufferSize?.clamp(50, 10000),
    );
    final logStream = localLogStream = LogStreamSubscriber();

    await vm.connect(Uri.parse(resolvedVmServiceUri));

    // Multi-isolate (Phase 10): discover every isolate that exposes
    // ext.dart.io.getHttpProfile, not just the first. enableHttpLogging /
    // enableSocketProfiling fire per-isolate so every one's traffic flows
    // into the capture writer's per-isolate poll. The session row's
    // `isolate_id` column stores the first isolate (for back-compat with
    // session metadata that assumed one isolate per session).
    final allIsolates = await vm.discoverHttpProfilingIsolates();
    if (allIsolates.isEmpty) {
      throw StateError(
        'No running isolate exposes dart:io HTTP profiling. '
        'Is the target a Flutter/Dart app that uses HttpClient / package:http?',
      );
    }
    final primaryIsolateId = allIsolates.first.id;

    final caps = CapabilityConfig.instance;
    bool anyHttpEnabled = false;
    bool anySocketEnabled = false;
    for (final iso in allIsolates) {
      try {
        final state = await vm.enableHttpLoggingForIsolate(iso.id);
        if (state.enabled) anyHttpEnabled = true;
      } catch (_) {/* embedder may not support per-isolate enable */}
      if (caps.isEnabled(Category.sockets)) {
        try {
          if (await vm.enableSocketProfilingForIsolate(iso.id)) {
            anySocketEnabled = true;
          }
        } catch (_) {/* harmless */}
      }
    }
    // Local synonyms so the rest of the function reads naturally.
    final httpEnabled = anyHttpEnabled;
    final socketEnabled = anySocketEnabled;
    final isolateId = primaryIsolateId;

    final dao = CapturesDao();
    final sid = dao.createSession(
      appName: appName,
      vmServiceUri: resolvedVmServiceUri,
      isolateId: isolateId,
      projectPath: io.Directory.current.path,
    );

    if (caps.isEnabled(Category.logs)) {
      await logStream.start(
        vm.service,
        logBuffer,
        // Closure-capture the just-created session id rather than re-reading
        // Session.instance.liveSessionId — supports the multi-attach case
        // where there is no single "current" session.
        sessionIdProvider: () => sid,
      );
    }

    captureWriter.start(vm, sid);

    // Publish the fully-built session to the registry. After this point,
    // Session.instance's delegated getters reflect this attach.
    SessionRegistry.instance.register(
      AttachedSession(
        id: sid,
        appName: appName,
        vmServiceUri: resolvedVmServiceUri,
        isolateId: isolateId,
        vm: vm,
        captureWriter: captureWriter,
        logBuffer: logBuffer,
        logStream: logStream,
        attachedAt: DateTime.now(),
        httpProfilingEnabled: httpEnabled,
        socketProfilingEnabled: socketEnabled,
      ),
    );

    // 0.7.3: persist the current attachment set so a future Claude Code
    // reload can surface "you were on sanga_mobile 47 min ago — reattach?"
    SessionContinuation.record(registry.attached.values);

    // 0.7.3: lazily start the anomaly detector now that we have at least
    // one session to watch. Idempotent — no-op when already running.
    AnomalyDetector.instance.startIfNeeded();

    // Synthesize warnings for partial degradation.
    final warnings = <String>[];
    if (!httpEnabled) {
      warnings.add(
        'HTTP timeline logging did not enable cleanly — captured requests may be incomplete.',
      );
    }
    if (caps.isEnabled(Category.sockets) && !socketEnabled) {
      warnings.add(
        'socket profiling unavailable on this isolate — socket_* tools will return empty.',
      );
    }
    if (caps.isEnabled(Category.logs) && !logStream.isActive) {
      warnings.add(
        'log stream subscription did not start — logs_tail will be empty.',
      );
    }

    // Capability-aware nextSteps for the post-attach read tools.
    final readTools = <String>[];
    if (caps.isEnabled(Category.http)) readTools.add('network_list');
    if (caps.isEnabled(Category.logs) && logStream.isActive) {
      readTools.add('logs_tail');
    }
    if (caps.isEnabled(Category.alerts)) readTools.add('alerts_drain');
    final secondStep = readTools.isEmpty
        ? 'Then read via the enabled tools (see network_status.capabilities)'
        : 'Then call ${readTools.join(' / ')}';

    // One-line summary the agent can echo back to the user.
    final captured = <String>[];
    if (httpEnabled) captured.add('HTTP');
    if (socketEnabled) captured.add('sockets');
    if (logStream.isActive) captured.add('logs');
    final what =
        captured.isEmpty ? 'no streams (degraded)' : captured.join('+');
    final summary = registry.attachedCount > 1
        ? 'Attached to ${appName ?? "app"} — capturing $what into session $sid. ${registry.attachedCount} sessions now attached.'
        : 'Attached to ${appName ?? "app"} — capturing $what into session $sid.';

    final autoAttachSuggestion = _buildAutoAttachSuggestion(appName);

    // #17: structured per-session capability health so degradation is hard to
    // miss (warnings alone get scanned past). socket_* / logs_* tools key off
    // the same flags and return a real error when their capability is
    // `unavailable` rather than an empty array.
    final capState = sessionCapabilities(
      httpOk: httpEnabled,
      socketOk: socketEnabled,
      logsOk: logStream.isActive,
    );

    return {
      'attached': true,
      'summary': summary,
      'scope': {'sessionId': sid, if (appName != null) 'appName': appName, 'isLive': true},
      'appName': appName,
      'vmServiceUri': resolvedVmServiceUri,
      'isolateId': isolateId,
      'liveSessionId': sid,
      'socketProfilingEnabled': socketEnabled,
      'capabilities': capState.capabilities,
      if (capState.degraded.isNotEmpty) 'degraded': capState.degraded,
      'attachedCount': registry.attachedCount,
      if (warnings.isNotEmpty) 'warnings': warnings,
      if (autoAttachSuggestion != null)
        'autoAttachSuggestion': autoAttachSuggestion,
      'nextSteps': [
        'Drive the app to generate traffic',
        if (registry.attachedCount > 1)
          'Subsequent reads need sessionId:$sid (or appNameContains) to disambiguate'
        else
          secondStep,
        if (autoAttachSuggestion != null)
          'autoAttachSuggestion — ask the user whether to add "${autoAttachSuggestion['pattern']}" to FLUTTER_NETWORK_MCP_AUTO_ATTACH for future sessions',
      ],
    };
  } catch (e, st) {
    // Stack trace goes to stderr only — never into the LLM context.
    io.stderr.writeln('network_attach failed: $e\n$st');
    // Tear down any partially-built local resources directly (we never
    // registered, so the registry doesn't see them).
    localCaptureWriter?.stop();
    if (localLogStream != null) await localLogStream.stop();
    if (localVm != null) await localVm.disconnect();
    // Only disconnect DTD if THIS attempt brought it up and nothing else
    // is using it. If other sessions are still attached, leave DTD alone.
    if (!dtdWasConnectedBefore && registry.attachedCount == 0) {
      await session.dtd.disconnect();
    }
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

/// Builds an onboarding hint asking the agent to PROMPT the user about
/// adding the freshly-attached app to the auto-attach allowlist. Returns
/// null when the app is already covered by the allowlist (no nag) or when
/// we don't have a usable app name to suggest.
///
/// **Important contract for the agent**: this hint instructs the agent
/// to ASK the user before editing anything. The agent must not silently
/// append to the user's shell rc — the suggested shell line is provided
/// as a paste-ready string for the user to confirm.
Map<String, Object?>? _buildAutoAttachSuggestion(String? appName) {
  if (appName == null || appName.isEmpty) return null;
  if (AutoAttachConfig.matchesAllowlist(appName)) return null;

  // Pull a stable, recognizable token from the full DTD name. DTD app
  // names look like "Flutter - iPhone 17 - Package: sanga_mobile"; the
  // user's allowlist convention is the package name ("sanga_mobile"),
  // not the whole string.
  final pattern = _extractPattern(appName);

  final currentAllowlist = AutoAttachConfig.allowedPatterns;
  final enabled = AutoAttachConfig.isEnabled;

  final newAllowlist = [...currentAllowlist, pattern].join(',');
  final shellLine = 'export FLUTTER_NETWORK_MCP_AUTO_ATTACH=$newAllowlist';

  final agentAction = enabled
      ? 'Auto-attach is enabled but "$pattern" isn\'t in the current '
        'allowlist (${currentAllowlist.join(", ")}). ASK THE USER: '
        '"Would you like flutter_network_mcp to auto-attach to $pattern '
        'on future MCP launches?" If they confirm, append the '
        'suggestedShellLine below to their shell rc (e.g. ~/.zshrc on '
        'macOS, ~/.bashrc on Linux), then have them restart their MCP '
        'host (e.g. /quit then re-open Claude Code). DO NOT edit the '
        'rc file without explicit user confirmation.'
      : 'Auto-attach isn\'t configured yet. ASK THE USER: "Would you like '
        'flutter_network_mcp to auto-attach to $pattern on future MCP '
        'launches? This means future sessions will skip the manual '
        'network_attach step." If they confirm, append the '
        'suggestedShellLine below to their shell rc (e.g. ~/.zshrc on '
        'macOS, ~/.bashrc on Linux), then have them restart their MCP '
        'host. DO NOT edit the rc file without explicit user confirmation.';

  return {
    'enabled': enabled,
    'matchesAllowlist': false,
    'appName': appName,
    'pattern': pattern,
    'currentAllowlist': currentAllowlist,
    'suggestedShellLine': shellLine,
    'agentAction': agentAction,
  };
}

/// Extracts a stable allowlist token from a DTD app name.
///
/// DTD app names typically look like:
///   "Flutter - iPhone 17 - Package: sanga_mobile"
///   "Flutter - macOS - Package: sanga_driver"
///
/// We want the user's allowlist to be `sanga_mobile`, not the whole
/// string (which embeds device + form factor noise that breaks the
/// substring match when the device changes). Strategy: take everything
/// after "Package: " when present; otherwise fall back to the full name.
String _extractPattern(String appName) {
  const marker = 'Package:';
  final idx = appName.indexOf(marker);
  if (idx == -1) return appName.trim();
  return appName.substring(idx + marker.length).trim();
}
