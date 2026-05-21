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
      'Reports current attachment state, active capabilities, known DTD apps, '
      'and a pending-alert count. Safe to call any time. Useful as a passive '
      'hint — when alerts.pending > 0, call alerts_drain or alerts_peek.',
  inputSchema: Schema.object(properties: {}),
);

FutureOr<CallToolResult> networkStatus(
  CallToolRequest request,
  String? defaultDtdUri,
) async {
  final session = Session.instance;
  final caps = CapabilityConfig.instance;
  final out = <String, Object?>{
    'attached': session.isAttached,
    'capabilities': [for (final c in caps.enabled) c.key],
    'dtd': {
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

  if (CapturesDatabase.isOpen && caps.isEnabled(Category.alerts)) {
    try {
      final dao = CapturesDao();
      final pending = dao.pendingAlertCount(sessionId: session.effectiveSessionId);
      final critical = dao.pendingAlertCount(
        sessionId: session.effectiveSessionId,
        severityMin: 'critical',
      );
      out['alerts'] = {'pending': pending, 'critical': critical};
    } catch (_) {
      out['alerts'] = {'pending': 0, 'critical': 0};
    }
  }

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

  return jsonResult(out);
}
