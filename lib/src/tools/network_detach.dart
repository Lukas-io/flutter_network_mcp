import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../alerts/anomaly_detector.dart';
import '../state/continuation.dart';
import '../state/session.dart';
import '../storage/captures_db.dart';
import 'result.dart';

final networkDetachTool = Tool(
  name: 'network_detach',
  description:
      'Stop capture for one attached session (or all with all:true). Ends '
      'the DB session (rows stay queryable). DTD disconnects when nothing '
      'remains. Zero-arg works only when exactly one session is attached.',
  inputSchema: Schema.object(
    properties: {
      'sessionId': Schema.int(
        description:
            'Attached session to detach. Omit when exactly one is attached. '
            'Ignored when all:true.',
      ),
      'appNameContains': Schema.string(
        description: 'Pick the session by app-name substring instead of sessionId.',
      ),
      'all': Schema.bool(
        description: 'Detach every attached session.',
      ),
    },
  ),
);

FutureOr<CallToolResult> networkDetach(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final registry = SessionRegistry.instance;
  final session = Session.instance;
  final all = (args['all'] as bool?) ?? false;
  final sessionIdArg = args['sessionId'] as int?;
  final appNameContains = args['appNameContains'] as String?;

  // No-op when there's nothing attached.
  if (registry.attachedCount == 0) {
    return jsonResult({
      'detached': true,
      'summary': 'No-op: nothing attached.',
      'wasAttached': false,
      'remainingAttached': 0,
      'nextSteps': const [
        'network_status — see what apps are reachable',
        'network_attach — connect to a live app',
        'session_list — view past sessions',
      ],
    });
  }

  // Decide which session(s) to detach.
  final List<AttachedSession> targets;
  if (all) {
    targets = List<AttachedSession>.from(registry.attached.values);
  } else if (sessionIdArg != null) {
    final s = registry.attachedById(sessionIdArg);
    if (s == null) {
      return errorResult(
        'No attached session with id $sessionIdArg.',
        extra: {
          'attached': [
            for (final a in registry.attached.values)
              {'sessionId': a.id, 'appName': a.appName},
          ],
          'nextSteps': const [
            'network_status — list attached sessions',
            'network_detach all:true — drop everything',
          ],
        },
      );
    }
    targets = [s];
  } else if (appNameContains != null && appNameContains.isNotEmpty) {
    final matches = registry.findByAppName(appNameContains);
    if (matches.isEmpty) {
      return errorResult(
        'No attached session whose app name contains "$appNameContains".',
        extra: {
          'attached': [
            for (final a in registry.attached.values)
              {'sessionId': a.id, 'appName': a.appName},
          ],
          'nextSteps': const [
            'Try a different substring or sessionId',
            'network_status — list attached sessions',
          ],
        },
      );
    }
    if (matches.length > 1) {
      return errorResult(
        'Multiple attached sessions match "$appNameContains" '
        '(${matches.length}).',
        extra: {
          'matches': [
            for (final m in matches)
              {'sessionId': m.id, 'appName': m.appName},
          ],
          'nextSteps': const [
            'Pass sessionId:<N> for one specific match',
            'network_detach all:true — drop them all',
          ],
        },
      );
    }
    targets = [matches.single];
  } else {
    // Zero-arg: only OK when exactly one is attached.
    if (registry.attachedCount > 1) {
      return errorResult(
        'Ambiguous detach: ${registry.attachedCount} sessions attached. '
        'Pass sessionId:<N>, appNameContains:<substring>, or all:true.',
        extra: {
          'attached': [
            for (final a in registry.attached.values)
              {'sessionId': a.id, 'appName': a.appName},
          ],
          'nextSteps': [
            for (final a in registry.attached.values)
              'network_detach sessionId:${a.id}  // ${a.appName ?? "(no name)"}',
            'network_detach all:true — drop everything',
          ],
        },
      );
    }
    targets = [registry.attached.values.single];
  }

  // Gather counts BEFORE teardown so the summary can report them.
  final detached = <Map<String, Object?>>[];
  int totalHttp = 0, totalLogs = 0, totalAlerts = 0;
  final dao = CapturesDao();
  for (final s in targets) {
    int httpCount = 0, logCount = 0, alertCount = 0;
    try {
      final r = dao.rawSelect(
        'SELECT '
        '(SELECT COUNT(*) FROM http_requests WHERE session_id=${s.id}) AS http_n, '
        '(SELECT COUNT(*) FROM log_records WHERE session_id=${s.id}) AS log_n, '
        '(SELECT COUNT(*) FROM alerts WHERE session_id=${s.id}) AS alert_n',
      );
      if (r.isNotEmpty) {
        httpCount = (r.first['http_n'] as int?) ?? 0;
        logCount = (r.first['log_n'] as int?) ?? 0;
        alertCount = (r.first['alert_n'] as int?) ?? 0;
      }
      dao.endSession(s.id);
    } catch (_) {/* DB may be mid-state */}
    totalHttp += httpCount;
    totalLogs += logCount;
    totalAlerts += alertCount;
    detached.add({
      'sessionId': s.id,
      if (s.appName != null) 'appName': s.appName,
      'captured': {
        'http': httpCount,
        'logs': logCount,
        'alerts': alertCount,
      },
    });
    await registry.detachOne(s);
  }

  // Clear history-view pointer if it was pointing at one of these.
  for (final s in targets) {
    if (session.viewedSessionId == s.id) {
      session.viewedSessionId = null;
      break;
    }
  }

  // Disconnect DTD when no sessions remain attached.
  if (registry.attachedCount == 0 && session.dtd.isConnected) {
    await session.dtd.disconnect();
  }

  // 0.7.3: update the continuation record so a future MCP-host restart
  // sees only the still-attached sessions (or no continuation at all
  // when the user has explicitly detached everything).
  if (registry.attachedCount == 0) {
    SessionContinuation.clear();
  } else {
    SessionContinuation.record(registry.attached.values);
  }

  // 0.7.3: shut down the anomaly detector when no sessions remain — no
  // work to do until the next attach.
  AnomalyDetector.instance.stopIfNoSessions();

  final remaining = registry.attachedCount;
  final summary = targets.length == 1
      ? 'Detached from ${targets.single.appName ?? "app"}. '
          'Session ${targets.single.id} ended — captured $totalHttp http, '
          '$totalLogs log(s), $totalAlerts alert(s). Queryable via '
          'session_open id:${targets.single.id}. '
          '${remaining == 0 ? "DTD disconnected." : "$remaining session(s) still attached."}'
      : 'Detached from ${targets.length} session(s) — captured $totalHttp '
          'http, $totalLogs log(s), $totalAlerts alert(s) total. DTD '
          'disconnected.';

  return jsonResult({
    'detached': true,
    'summary': summary,
    'wasAttached': true,
    'detachedSessions': detached,
    'remainingAttached': remaining,
    'captured': {'http': totalHttp, 'logs': totalLogs, 'alerts': totalAlerts},
    'nextSteps': remaining == 0
        ? [
            for (final d in detached)
              'session_open id:${d['sessionId']} — view what was captured',
            'session_list — see all sessions including these',
            'network_attach — reconnect to capture more (or a different app)',
          ]
        : [
            'network_status — see remaining attached sessions',
            for (final d in detached)
              'session_open id:${d['sessionId']} — view what was captured',
          ],
  });
}
