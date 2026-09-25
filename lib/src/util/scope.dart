import 'dart:io' as io;

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../tools/error_kind.dart';
import '../tools/network_attach.dart' show appSessionIdentity;
import '../tools/result.dart';

/// Resolved routing scope for a single tool call — which session the tool
/// should answer for, and whether that session is currently live-attached.
class Scope {
  Scope({
    required this.sessionId,
    required this.appName,
    required this.isLive,
    this.note,
    this.pickedBy,
    this.others = const [],
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

  /// Set when this scope was resolved through state that could surprise the
  /// agent (an open view shadowing live sessions, a dead session's history).
  /// Tools surface it as a warning via `jsonResult(scope: ...)`.
  final String? note;

  /// How a default scope was chosen when several sessions were live:
  /// `project` (same working directory) or `recent` (last touched).
  final String? pickedBy;

  /// The other live sessions the call could have targeted.
  final List<Map<String, Object?>> others;

  /// Compact `scope: {…}` block tools include in successful responses so
  /// the agent can verify which session it just read from.
  Map<String, Object?> toBlock() => {
        'sessionId': sessionId,
        if (appName != null) 'appName': appName,
        'isLive': isLive,
        if (note != null) 'note': note,
        if (pickedBy != null) 'pickedBy': pickedBy,
        if (others.isNotEmpty) 'others': others,
      };
}

/// Where a dead session's app is now, when the last DTD probe saw the same
/// app identity at another URI. Null when unknown.
String? movedToFor(SessionRegistry reg, DeadSession d) {
  final identity = appSessionIdentity(d.appName);
  if (identity == null) return null;
  for (final e in reg.lastLiveApps.entries) {
    if (e.key != d.vmServiceUri && appSessionIdentity(e.value) == identity) {
      return e.key;
    }
  }
  return null;
}

/// The warning a read against a dead session carries.
String deadSessionNote(SessionRegistry reg, DeadSession d) {
  final moved = movedToFor(reg, d);
  final when = d.diedAt.toIso8601String().substring(11, 19);
  return 'session ${d.sessionId} is no longer reachable (${d.reason} at $when); '
      'this reply is its preserved history, not live data'
      '${moved != null ? ". The app is now at $moved — network_attach vmServiceUri:\"$moved\" to follow it" : ""}.';
}

/// The session a bare read targets when several are live: the one attached
/// from [projectPath], else the most recently touched. Pure and testable.
({AttachedSession session, String by})? pickDefaultSession(
    SessionRegistry reg, String projectPath) {
  final byProject = reg.liveForProject(projectPath);
  // The project only counts as the reason when it actually narrowed the
  // choice; every session this server attached shares its cwd.
  if (byProject.isNotEmpty && byProject.length < reg.liveCount) {
    return (session: byProject.first, by: 'project');
  }
  final recent = reg.mostRecentLive;
  if (recent != null) return (session: recent, by: 'recent');
  return null;
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
      attached.touch();
      return (
        Scope(
          sessionId: sessionIdArg,
          appName: attached.appName,
          isLive: true,
        ),
        null,
      );
    }
    final dead = reg.deadById(sessionIdArg);
    return (
      Scope(
        sessionId: sessionIdArg,
        appName: dead?.appName,
        isLive: false,
        note: dead == null ? null : deadSessionNote(reg, dead),
      ),
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
          kind: ErrorKind.noSession,
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
          kind: ErrorKind.badArgument,
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
    // D2/F4: an open view silently outranks live sessions. When that is
    // actually happening (view ≠ the live attach, and live sessions
    // exist), say so on every read instead of letting the agent believe
    // it is reading live data.
    final shadowing = attached == null && reg.attachedCount > 0;
    return (
      Scope(
        sessionId: viewedId,
        appName: attached?.appName,
        isLive: false,
        note: shadowing
            ? 'Reading HISTORY session $viewedId via session_open while '
                '${reg.attachedCount} live session(s) are attached — '
                'session_close to target live captures.'
            : attached != null
                ? 'Reading session $viewedId from history (everything persisted '
                    'so far) although it is live — session_close to return to '
                    'incremental live reads.'
                : null,
      ),
      null,
    );
  }

  final sole = reg.soleAttached;
  if (sole != null) {
    sole.touch();
    return (
      Scope(sessionId: sole.id, appName: sole.appName, isLive: true),
      null,
    );
  }

  if (reg.attachedCount >= 2) {
    final picked = pickDefaultSession(reg, io.Directory.current.path);
    if (picked != null) {
      picked.session.touch();
      return (
        Scope(
          sessionId: picked.session.id,
          appName: picked.session.appName,
          isLive: true,
          pickedBy: picked.by,
          others: [
            for (final a in reg.attached.values)
              if (a.id != picked.session.id)
                {'sessionId': a.id, if (a.appName != null) 'appName': a.appName},
          ],
        ),
        null,
      );
    }
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
        kind: ErrorKind.noSession,
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
      kind: ErrorKind.badArgument,
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
