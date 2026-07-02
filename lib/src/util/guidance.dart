import '../state/session.dart';
import '../storage/captures_db.dart';
import '../storage/database.dart';

/// D1 (agent-UX audit RC8): one queryable truth about a session's state, so
/// guidance strings are derived from reality instead of hardcoded for the
/// live-happy-path. Before this, an agent reading a 3-day-old ended session
/// was told to "drive the app to generate traffic" — a confident
/// impossibility that erodes trust in every other hint.
class SessionStateView {
  SessionStateView._({
    required this.sessionId,
    required this.isAttached,
    required this.isEnded,
    required this.appDied,
    required this.isViewing,
    this.endedAtMs,
  });

  final int sessionId;

  /// A live capture is running for this session right now.
  final bool isAttached;

  /// The session has a recorded end (`ended_at` set — clean detach or the
  /// RC4 app-death handler).
  final bool isEnded;

  /// The app for this session died while attached (RC4 recentlyDied).
  final bool appDied;

  /// Reads are routed here via session_open.
  final bool isViewing;

  final int? endedAtMs;

  /// Not attached and no recorded end: the capture stopped without a clean
  /// detach (server killed pre-0.9.17, crash, etc.).
  bool get isInterrupted => !isAttached && !isEnded;

  /// True when telling the agent to "drive the app" makes any sense.
  bool get canGenerateTraffic => isAttached && !appDied;

  static SessionStateView of(int sessionId) {
    final registry = SessionRegistry.instance;
    final attached = registry.attachedById(sessionId) != null;
    int? endedAtMs;
    var ended = false;
    if (CapturesDatabase.isOpen) {
      try {
        final row = CapturesDao().getSession(sessionId);
        endedAtMs = row?['ended_at'] as int?;
        ended = endedAtMs != null;
      } catch (_) {/* DB closing — treat as unknown */}
    }
    return SessionStateView._(
      sessionId: sessionId,
      isAttached: attached,
      isEnded: ended,
      appDied: registry.recentlyDied.any((d) => d.sessionId == sessionId),
      isViewing: Session.instance.viewedSessionId == sessionId,
      endedAtMs: endedAtMs,
    );
  }
}

/// Tri-state label for session displays (F11): "live" only when actually
/// attached; a NULL ended_at on a non-attached session is "interrupted",
/// never "still live".
String sessionStatusLabel({
  required bool isAttached,
  required Object? endedAtMs,
}) {
  if (isAttached) return 'live';
  if (endedAtMs != null) return 'ended';
  return 'interrupted';
}

/// State-correct replacement for the "Drive the app…" family. Returns a
/// hint that is actually actionable in [state]:
///  - attached & healthy  → drive the app (the classic).
///  - app died            → the capture is final; route to what exists.
///  - ended / interrupted → this is the complete record.
String emptyCaptureHint(SessionStateView state, {required String reRun}) {
  if (state.canGenerateTraffic) {
    return 'Drive the app to generate traffic, then re-run $reRun.';
  }
  if (state.appDied) {
    return 'The app for session ${state.sessionId} exited — this capture is '
        'final. Whatever was recorded is all there is.';
  }
  final how = state.isEnded ? 'ended' : 'was interrupted (no clean end)';
  return 'Session ${state.sessionId} $how — this is its complete capture; '
      'nothing new will arrive.';
}
