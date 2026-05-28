import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../config/capabilities.dart';
import '../state/session.dart';
import '../storage/captures_db.dart';
import '../storage/database.dart';
import 'network_attach.dart' as attach_helper;
import 'result.dart';

final networkStatusTool = Tool(
  name: 'network_status',
  description:
      'Call this FIRST, every session. Tells you: which apps are reachable '
      'to attach to (`knownApps` — pick one of these for network_attach), '
      'WHICH sessions are currently attached (`attached: []` list — '
      'multi-attach in 0.6.0 allows N concurrent sessions), what alerts '
      'are queued, what capabilities are enabled, and which DB on disk '
      'you\'re writing to. Auto-opens the DTD connection so `knownApps` '
      'populates without a separate attach step — pass `connectDtd:false` '
      'to skip that probe. Reads `nextSteps` from the response to know '
      'what to call next.',
  inputSchema: Schema.object(
    properties: {
      'connectDtd': Schema.bool(
        description:
            'When true (default), opportunistically opens the DTD connection '
            'to populate knownApps. Set false for a pure in-process state read.',
      ),
      'attachIfOne': Schema.bool(
        description:
            'When true AND zero sessions are currently attached AND exactly '
            'one app is visible on DTD, auto-attaches and includes the '
            'attach result under `autoAttached`. Default false — status '
            'stays a read-only check.',
      ),
    },
  ),
);

FutureOr<CallToolResult> networkStatus(
  CallToolRequest request,
  String? defaultDtdUri,
) async {
  final args = request.arguments ?? const <String, Object?>{};
  final connectDtd = (args['connectDtd'] as bool?) ?? true;
  final attachIfOne = (args['attachIfOne'] as bool?) ?? false;

  final session = Session.instance;
  final registry = SessionRegistry.instance;
  final caps = CapabilityConfig.instance;
  final allEnabled = caps.enabled.length == Category.values.length;

  // Build the per-session attached list. Empty when nothing attached.
  // Phase 10: each entry's `isolates: [...]` lists every HTTP-profiling
  // isolate the capture writer is currently polling. Single-isolate apps
  // see a one-element list; apps spawning workers see more (and grow as
  // the writer's periodic re-scan picks up new isolates).
  final attachedList = <Map<String, Object?>>[
    for (final a in registry.attached.values)
      {
        'sessionId': a.id,
        if (a.appName != null) 'appName': a.appName,
        'vmServiceUri': a.vmServiceUri,
        if (a.isolateId != null) 'isolateId': a.isolateId,
        'isolates': [for (final iso in a.isolates) iso.toJson()],
        'attachedAtMs': a.attachedAt.millisecondsSinceEpoch,
        'httpProfilingEnabled': a.httpProfilingEnabled,
        if (a.socketProfilingEnabled) 'socketProfilingEnabled': true,
      },
  ];

  final out = <String, Object?>{
    'attachedCount': registry.attachedCount,
    'attached': attachedList,
    // Compact: emit "all" instead of the 8-element list in the common case.
    'capabilities': allEnabled ? 'all' : [for (final c in caps.enabled) c.key],
    'dtd': <String, Object?>{
      'connected': session.dtd.isConnected,
      'uri': session.dtd.connectedUri?.toString(),
      'defaultUri': defaultDtdUri,
    },
    if (session.viewedSessionId != null)
      'viewedSessionId': session.viewedSessionId,
  };

  // Opportunistic DTD connect so knownApps lands on the first status call.
  String? connectError;
  if (connectDtd && !session.dtd.isConnected && defaultDtdUri != null) {
    try {
      await session.dtd
          .connect(Uri.parse(defaultDtdUri))
          .timeout(const Duration(seconds: 5));
      (out['dtd'] as Map<String, Object?>)['connected'] = true;
      (out['dtd'] as Map<String, Object?>)['uri'] = defaultDtdUri;
    } catch (e) {
      connectError = e.toString();
    }
  }

  if (connectError != null) {
    (out['dtd'] as Map<String, Object?>)['connectError'] = connectError;
  }

  // DB-level context: path, session count, and alert totals across all
  // sessions PLUS per-attached-session breakdown when multi-attach.
  if (CapturesDatabase.isOpen) {
    out['dbPath'] = CapturesDatabase.instance.path;
    try {
      final dao = CapturesDao();
      final sessions =
          dao.rawSelect('SELECT COUNT(*) AS n FROM sessions').first['n'];
      out['sessionCount'] = sessions;
      if (caps.isEnabled(Category.alerts)) {
        final alertsBlock = <String, Object?>{
          'pendingTotal': dao.pendingAlertCount(),
          'critical': dao.pendingAlertCount(severityMin: 'critical'),
        };
        // Per-session breakdown only when 2+ attached (otherwise redundant
        // with pendingTotal).
        if (registry.attachedCount >= 2) {
          alertsBlock['perAttached'] = [
            for (final a in registry.attached.values)
              {
                'sessionId': a.id,
                if (a.appName != null) 'appName': a.appName,
                'pending': dao.pendingAlertCount(sessionId: a.id),
              },
          ];
        }
        out['alerts'] = alertsBlock;
      }
    } catch (_) {/* DB might be mid-migration on first run */}
  }

  // App discovery — possible now that DTD may be auto-connected above.
  if (session.dtd.isConnected) {
    try {
      final apps = await session.dtd.getConnectedApps();
      out['knownApps'] = [
        for (final app in apps)
          {
            'name': app.name,
            'uri': app.uri,
            if (app.exposedUri != null) 'exposedUri': app.exposedUri,
          },
      ];
    } catch (e) {
      out['knownAppsError'] = e.toString();
    }
  }

  // Opt-in one-shot orient+attach: only fires when nothing is attached
  // yet and exactly one app is visible.
  if (attachIfOne && registry.attachedCount == 0) {
    final apps = out['knownApps'] as List?;
    if (apps != null && apps.length == 1 && defaultDtdUri != null) {
      final result = await attach_helper.performAttach(
        defaultDtdUri: defaultDtdUri,
      );
      out['autoAttached'] = result;
      if (result['attached'] == true) {
        // Refresh the attached list now that registration happened.
        out['attachedCount'] = registry.attachedCount;
        (out['attached'] as List).clear();
        for (final a in registry.attached.values) {
          (out['attached'] as List).add({
            'sessionId': a.id,
            if (a.appName != null) 'appName': a.appName,
            'vmServiceUri': a.vmServiceUri,
            if (a.isolateId != null) 'isolateId': a.isolateId,
            'isolates': [for (final iso in a.isolates) iso.toJson()],
            'attachedAtMs': a.attachedAt.millisecondsSinceEpoch,
            'httpProfilingEnabled': a.httpProfilingEnabled,
            if (a.socketProfilingEnabled) 'socketProfilingEnabled': true,
          });
        }
      }
    }
  }

  out['nextSteps'] = _suggestNextSteps(registry, session, out);

  return jsonResult(out);
}

/// Returns 1–2 short hints telling the agent what to do given the current
/// state.
List<String> _suggestNextSteps(
  SessionRegistry registry,
  Session session,
  Map<String, Object?> out,
) {
  final steps = <String>[];
  final alertsBlock = out['alerts'] as Map<String, Object?>?;
  final pendingTotal = (alertsBlock?['pendingTotal'] as int?) ?? 0;
  final critical = (alertsBlock?['critical'] as int?) ?? 0;
  final knownApps = out['knownApps'] as List?;
  final attachedCount = registry.attachedCount;

  // Attached path.
  if (attachedCount > 0) {
    if (critical > 0) {
      steps.add('alerts_drain severityMin:"critical" — $critical critical alert(s) pending');
    } else if (pendingTotal > 0) {
      steps.add(
        attachedCount > 1
            ? 'alerts_drain sessionId:<N> — $pendingTotal pending alert(s) across attached sessions (see alerts.perAttached for breakdown)'
            : 'alerts_drain — $pendingTotal pending alert(s) in the attached session',
      );
    }
    if (session.viewedSessionId != null) {
      steps.add('session_close to revert read pointer to live (currently viewing session ${session.viewedSessionId})');
    }
    if (attachedCount > 1) {
      steps.add(
        'Reads must pass sessionId or appNameContains to disambiguate '
        '($attachedCount sessions attached)',
      );
    }
    if (steps.isEmpty) {
      steps.add(
        attachedCount > 1
            ? 'Drive the apps; reads to a specific app need sessionId:<N> from the attached[] list'
            : 'Drive the app, then call network_list (returns nextCursor for incremental polling)',
      );
    }
    return steps;
  }

  // Not attached.
  final dtd = out['dtd'] as Map<String, Object?>;
  final dtdConnected = (dtd['connected'] as bool?) ?? false;
  final defaultUri = dtd['defaultUri'] as String?;

  if (!dtdConnected && defaultUri == null) {
    steps.add('No DTD URI — start the server with --dtd-uri or pass dtdUri/vmServiceUri to network_attach');
    return steps;
  }
  if (!dtdConnected && defaultUri != null) {
    steps.add('DTD connect failed; check the URI is still valid (see dtd.connectError)');
    return steps;
  }
  if (knownApps == null || knownApps.isEmpty) {
    steps.add('DTD has no apps registered yet — launch a Flutter app, then re-check');
    return steps;
  }
  if (knownApps.length == 1) {
    steps.add('Call network_attach (one app available — will be auto-picked)');
  } else {
    steps.add(
      'Multiple apps visible (${knownApps.length}); call network_attach with explicit '
      'appNameContains / vmServiceUri. Multi-attach lets you attach to several '
      'at once — repeat the call for each app you want.',
    );
  }
  if (pendingTotal > 0) {
    steps.add(
      '$pendingTotal pending alert(s) across history — alerts_drain sessionId:<N> after attach',
    );
  }
  return steps;
}
