import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../tools/result.dart';

/// Resolved routing scope for a single tool call — which session the tool
/// should answer for, and whether that session is currently live-attached.
class Scope {
  Scope({
    required this.sessionId,
    required this.appName,
    required this.isLive,
  });

  /// DB row id in `sessions` table.
  final int sessionId;

  /// Display name (may be null when scoped to a historical session whose
  /// app name wasn't recorded, or when nothing is attached and the user
  /// passed an explicit historical sessionId).
  final String? appName;

  /// True when this scope points at a currently-attached session (i.e.
  /// live VM is available). False when scoped to a historical-only session
  /// via `session_open` or an explicit `sessionId:` arg.
  final bool isLive;

  /// Compact `scope: {…}` block tools include in successful responses so
  /// the agent can verify which session it just read from.
  Map<String, Object?> toBlock() => {
        'sessionId': sessionId,
        if (appName != null) 'appName': appName,
        'isLive': isLive,
      };
}

/// Resolves which session a tool should answer for. Priority:
///
/// 1. `sessionId: <int>` arg — explicit, no further checks.
/// 2. `appNameContains: <string>` arg — must match exactly one *attached*
///    session (case-insensitive substring).
/// 3. History mode: `Session.instance.viewedSessionId` when set via
///    `session_open`.
/// 4. Live: `SessionRegistry.instance.soleAttached` — the lone attached
///    session, when exactly one is attached.
///
/// Returns `(scope, null)` on success or `(null, errorResult)` when scope
/// cannot be resolved. The error payload always carries `attached: [...]`
/// (listing currently-attached sessions) and `nextSteps` with concrete
/// disambiguating commands.
///
/// Multi-attach (Phase 5+) makes priority 4 fail with an ambiguity error
/// when 2+ sessions are attached and no scope arg is given. Until Phase 5
/// lifts the single-attach guard, that path is unreachable in practice but
/// the resolver handles it correctly for forward compatibility.
(Scope?, CallToolResult?) resolveScope(Map<String, Object?> args) {
  final reg = SessionRegistry.instance;

  final sessionIdArg = args['sessionId'] as int?;
  if (sessionIdArg != null) {
    final attached = reg.attachedById(sessionIdArg);
    if (attached != null) {
      return (
        Scope(
          sessionId: sessionIdArg,
          appName: attached.appName,
          isLive: true,
        ),
        null,
      );
    }
    return (
      Scope(sessionId: sessionIdArg, appName: null, isLive: false),
      null,
    );
  }

  final appNameContains = args['appNameContains'] as String?;
  if (appNameContains != null && appNameContains.isNotEmpty) {
    final matches = reg.findByAppName(appNameContains);
    if (matches.isEmpty) {
      return (
        null,
        errorResult(
          'No attached session whose app name contains "$appNameContains".',
          extra: {
            'attached': _attachedSummary(reg),
            'nextSteps': [
              'Re-check the spelling or use a different substring',
              'network_status — see currently attached sessions',
              'network_attach appNameContains:"<unique>" — connect to a new app',
            ],
          },
        ),
      );
    }
    if (matches.length > 1) {
      return (
        null,
        errorResult(
          'Multiple attached sessions match "$appNameContains" '
          '(${matches.length}).',
          extra: {
            'matches': [
              for (final m in matches)
                {'sessionId': m.id, 'appName': m.appName},
            ],
            'nextSteps': [
              'Pass sessionId:<N> for one specific match',
              'Use a more unique appNameContains substring',
            ],
          },
        ),
      );
    }
    final m = matches.single;
    return (
      Scope(sessionId: m.id, appName: m.appName, isLive: true),
      null,
    );
  }

  final viewedId = Session.instance.viewedSessionId;
  if (viewedId != null) {
    final attached = reg.attachedById(viewedId);
    return (
      Scope(
        sessionId: viewedId,
        appName: attached?.appName,
        isLive: attached != null,
      ),
      null,
    );
  }

  final sole = reg.soleAttached;
  if (sole != null) {
    return (
      Scope(sessionId: sole.id, appName: sole.appName, isLive: true),
      null,
    );
  }

  if (reg.attachedCount == 0) {
    // RC4: if the last attach ended because the app died, say exactly that
    // and route to its history instead of a generic "not attached".
    final died = reg.recentlyDied.isEmpty ? null : reg.recentlyDied.first;
    return (
      null,
      errorResult(
        died != null
            ? 'Not attached: the app for session ${died.sessionId} '
                '(${died.appName ?? "unnamed"}) exited at '
                '${died.diedAt.toIso8601String()} and its session was ended '
                'automatically. Its capture is preserved — read it with '
                'session_open id:${died.sessionId}.'
            : 'Not attached and no session opened for viewing. Call '
                'network_attach to capture live, or session_open id:<N> to read '
                'from a historical session, or pass sessionId:<N> directly.',
        extra: {
          'nextSteps': [
            if (died != null)
              'session_open id:${died.sessionId} — read what the exited app captured',
            'network_status — see what apps are reachable',
            'network_attach — connect to a live app',
            'session_list — see historical sessions',
          ],
        },
      ),
    );
  }

  return (
    null,
    errorResult(
      'Ambiguous scope: ${reg.attachedCount} sessions attached. '
      'Pass sessionId:<N> or appNameContains:<substring>.',
      extra: {
        'attached': _attachedSummary(reg),
        'nextSteps': [
          for (final a in reg.attached.values)
            'sessionId:${a.id}  // ${a.appName ?? "(no name)"}',
        ],
      },
    ),
  );
}

List<Map<String, Object?>> _attachedSummary(SessionRegistry reg) => [
      for (final a in reg.attached.values)
        {'sessionId': a.id, 'appName': a.appName},
    ];
