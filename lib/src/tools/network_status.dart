import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../config/capabilities.dart';
import '../state/session.dart';
import '../storage/captures_db.dart';
import '../storage/database.dart';
import 'result.dart';

final networkStatusTool = Tool(
  name: 'network_status',
  description:
      'Auto-orienting first call. Reports attachment state, active '
      'capabilities, DTD-known apps, DB-wide alert counts, session totals, '
      'and a `nextSteps` hint of what to do. Auto-connects DTD when a '
      'default URI is configured so `knownApps` populates without needing '
      'to attach first. Pass `connectDtd:false` for a purely passive check.',
  inputSchema: Schema.object(
    properties: {
      'connectDtd': Schema.bool(
        description:
            'When true (default), opportunistically opens the DTD connection '
            'to populate knownApps. Set false for a pure in-process state read.',
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

  final session = Session.instance;
  final caps = CapabilityConfig.instance;
  final allEnabled = caps.enabled.length == Category.values.length;

  final out = <String, Object?>{
    'attached': session.isAttached,
    // Compact: emit "all" instead of the 8-element list in the common case.
    'capabilities': allEnabled ? 'all' : [for (final c in caps.enabled) c.key],
    'dtd': <String, Object?>{
      'connected': session.dtd.isConnected,
      'uri': session.dtd.connectedUri?.toString(),
      'defaultUri': defaultDtdUri,
    },
    'vmService': {
      'connected': session.vm.isConnected,
      'uri': session.vm.connectedUri?.toString(),
      'isolateId': session.vm.isolateId,
      'appName': session.attachedAppName,
    },
    'liveSessionId': session.liveSessionId,
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

  // DB-level context: path, session count, and alert totals across all sessions
  // PLUS the current scope.
  if (CapturesDatabase.isOpen) {
    out['dbPath'] = CapturesDatabase.instance.path;
    try {
      final dao = CapturesDao();
      final sessions =
          dao.rawSelect('SELECT COUNT(*) AS n FROM sessions').first['n'];
      out['sessionCount'] = sessions;
      if (caps.isEnabled(Category.alerts)) {
        final scopeSid = session.effectiveSessionId;
        out['alerts'] = {
          'pendingCurrent':
              scopeSid == null ? 0 : dao.pendingAlertCount(sessionId: scopeSid),
          'pendingTotal': dao.pendingAlertCount(),
          'critical': dao.pendingAlertCount(severityMin: 'critical'),
        };
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

  out['nextSteps'] = _suggestNextSteps(session, out);

  return jsonResult(out);
}

/// Returns 1–2 short hints telling the agent what to do given the current
/// state. Empty when fully attached and idle.
List<String> _suggestNextSteps(Session session, Map<String, Object?> out) {
  final steps = <String>[];
  final alertsBlock = out['alerts'] as Map<String, Object?>?;
  final pendingCurrent = (alertsBlock?['pendingCurrent'] as int?) ?? 0;
  final pendingTotal = (alertsBlock?['pendingTotal'] as int?) ?? 0;
  final critical = (alertsBlock?['critical'] as int?) ?? 0;
  final knownApps = out['knownApps'] as List?;

  if (session.isAttached) {
    if (critical > 0) {
      steps.add('alerts_drain severityMin:"critical" — $critical critical alert(s) pending');
    } else if (pendingCurrent > 0) {
      steps.add('alerts_drain — $pendingCurrent pending alert(s) in this session');
    }
    if (session.viewedSessionId != null) {
      steps.add('session_close to revert read pointer to live (currently viewing session ${session.viewedSessionId})');
    }
    if (steps.isEmpty) {
      steps.add('Drive the app, then call network_list (returns nextCursor for incremental polling)');
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
      'Multiple apps visible (${knownApps.length}); call network_attach with explicit vmServiceUri from knownApps',
    );
  }
  if (pendingTotal > 0) {
    steps.add(
      '$pendingTotal pending alert(s) across history — alerts_drain after attach or pass sessionId to scope to a past session',
    );
  }
  return steps;
}
