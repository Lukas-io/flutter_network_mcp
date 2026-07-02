import 'dart:async';
import 'dart:io' as io;

import '../state/session.dart';
import '../storage/captures_db.dart';
import '../storage/database.dart';
import 'alert_rules.dart';

/// Auto-expires old alerts so the pending banner reflects RECENT state, not
/// months of accumulated noise (feature request after the audit found the
/// banner grown to 14k+ over weeks of use).
///
/// Design: alerts older than `AlertRules.instance.alertRetentionDays` are
/// deleted, EXCEPT alerts of a currently-attached session (a long-lived
/// live session keeps all its alerts, however old). Runs independently of
/// attach state — a sweep on start (deferred, never blocks the handshake)
/// and every hour thereafter — so it works even when nothing is attached.
/// Retention of 0 disables it entirely (keep alerts forever).
///
/// Delete (not drain): retention is a data-lifecycle policy. cross-session
/// `priorOccurrences` still works within the window, which is the useful
/// horizon for "is this recurring recently?".
class AlertRetention {
  AlertRetention({Duration? interval, this.now})
      : interval = interval ?? const Duration(hours: 1);

  final Duration interval;

  /// Injectable clock for tests; defaults to wall time.
  final int Function()? now;

  Timer? _timer;
  final CapturesDao _dao = CapturesDao();

  bool get isRunning => _timer != null;

  void start() {
    stop();
    // Deferred first sweep: like the search-index repair, keep it off the
    // MCP-host JSON-RPC handshake path.
    Timer(const Duration(seconds: 8), sweep);
    _timer = Timer.periodic(interval, (_) => sweep());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Runs one retention pass. Public + returns the deleted count so tests
  /// (and a future manual-trigger tool) can drive it directly.
  int sweep() {
    final days = AlertRules.instance.alertRetentionDays;
    if (days <= 0) return 0; // disabled
    if (!CapturesDatabase.isOpen) return 0;
    final nowMs = (now ?? _wallMs)();
    final cutoff = nowMs - days * 86400000;
    final protected =
        SessionRegistry.instance.attached.values.map((s) => s.id).toSet();
    try {
      final deleted =
          _dao.expireOldAlerts(cutoffMs: cutoff, protectedSessionIds: protected);
      if (deleted > 0) {
        io.stderr.writeln(
          'flutter_network_mcp: alert retention expired $deleted alert(s) '
          'older than $days day(s).',
        );
      }
      return deleted;
    } catch (e) {
      io.stderr.writeln('flutter_network_mcp: alert retention sweep failed: $e');
      return 0;
    }
  }

  static int _wallMs() => DateTime.now().millisecondsSinceEpoch;
}
