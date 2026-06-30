import 'dart:io' as io;

import '../config/db_cap_config.dart';
import 'captures_db.dart';

/// What a single eviction sweep dropped. Surfaced by `db_stats` as
/// `lastEviction` so the loss is visible, never silent (issue #58).
class EvictionResult {
  EvictionResult({
    required this.bytesFreed,
    required this.bodiesDropped,
    required this.logsDropped,
    required this.sessionsDropped,
    required this.oldestRetainedMs,
    required this.atMs,
  });

  final int bytesFreed;
  final int bodiesDropped;
  final int logsDropped;
  final int sessionsDropped;
  final int? oldestRetainedMs;
  final int atMs;

  Map<String, Object?> toJson() => {
        'bytesFreed': bytesFreed,
        'bodiesDropped': bodiesDropped,
        'logsDropped': logsDropped,
        'sessionsDropped': sessionsDropped,
        if (oldestRetainedMs != null) 'oldestRetainedMs': oldestRetainedMs,
        'atMs': atMs,
      };
}

/// Default-on rolling size cap. The capture watchdog calls [maybeSweep] on a
/// low frequency (never the hot write path); when `captures.db` exceeds the cap
/// it evicts OLDEST-first — bodies (the dense bytes), then logs, then whole
/// sessions — down to ~90% of the cap, never touching the currently-attached
/// sessions, then vacuums so the file actually shrinks.
class DbCapManager {
  DbCapManager._();
  static final DbCapManager instance = DbCapManager._();

  final CapturesDao _dao = CapturesDao();

  /// Result of the most recent sweep, or null if none has run. Read by db_stats.
  Map<String, Object?>? lastEviction;

  /// True when a cap is configured (default on). The watchdog skips entirely
  /// when this is false.
  bool get isEnabled => DbCapConfig.enabled;

  /// Roughly the bytes a single `log_records` row costs on disk — used only to
  /// translate a byte target into a row count for log eviction.
  static const int _bytesPerLogRow = 200;

  /// True once we have warned that the DB is over cap but nothing is evictable
  /// (all remaining data belongs to attached sessions). Reset after any real
  /// eviction, so the warning fires on transition, not on every sweep.
  bool _warnedNothingEvictable = false;

  /// Checks the DB size and evicts if over the cap. Returns the sweep result,
  /// or null when disabled / already under cap. [protectedSessionIds] are the
  /// currently-attached sessions, which are never evicted. [nowMs] lets tests
  /// pin the timestamp.
  EvictionResult? maybeSweep({
    Set<int> protectedSessionIds = const {},
    int? nowMs,
  }) {
    final cap = DbCapConfig.maxBytes;
    if (cap == null) return null;

    final originalSize = _dao.dbSizeBytes();
    if (originalSize <= cap) return null;

    final target = (cap * 0.9).floor();
    final need = originalSize - target;

    var bodiesDropped = 0;
    var logsDropped = 0;
    var sessionsDropped = 0;

    // 1. Oldest bodies (exact bytes freed).
    final b = _dao.evictOldestBodies(
      targetBytes: need,
      protectedSessionIds: protectedSessionIds,
    );
    bodiesDropped = b.dropped;
    var freedEstimate = b.bytesFreed;

    // 2. Oldest logs, if bodies were not enough.
    if (freedEstimate < need) {
      final rowsNeeded = ((need - freedEstimate) / _bytesPerLogRow).ceil();
      logsDropped = _dao.evictOldestLogs(
        maxRows: rowsNeeded,
        protectedSessionIds: protectedSessionIds,
      );
      freedEstimate += logsDropped * _bytesPerLogRow;
    }

    // Reclaim the pages so the file shrinks, then measure for real.
    _dao.vacuum();
    var size = _dao.dbSizeBytes();

    // 3. Whole oldest sessions, if still over. Estimate how many to drop from
    // the average evictable-session size so we vacuum once, not per session.
    if (size > cap) {
      final evictable =
          _dao.sessionIdsOldestFirst(protectedSessionIds: protectedSessionIds);
      if (evictable.isNotEmpty) {
        final avg = (size / evictable.length).ceil();
        var toDrop = ((size - target) / avg).ceil();
        if (toDrop < 1) toDrop = 1;
        if (toDrop > evictable.length) toDrop = evictable.length;
        for (var i = 0; i < toDrop; i++) {
          if (_dao.deleteSession(evictable[i])) sessionsDropped++;
        }
        _dao.vacuum();
        size = _dao.dbSizeBytes();
      }
    }

    final result = EvictionResult(
      bytesFreed: originalSize - size,
      bodiesDropped: bodiesDropped,
      logsDropped: logsDropped,
      sessionsDropped: sessionsDropped,
      oldestRetainedMs: _dao.oldestRetainedRequestMs(),
      atMs: nowMs ?? DateTime.now().millisecondsSinceEpoch,
    );

    final droppedAnything =
        bodiesDropped > 0 || logsDropped > 0 || sessionsDropped > 0;
    if (!droppedAnything) {
      // Over cap, but everything left belongs to an attached session — we never
      // evict live data. Warn once on transition; don't clobber the last real
      // eviction record with a no-op result.
      if (!_warnedNothingEvictable) {
        _warnedNothingEvictable = true;
        io.stderr.writeln(
          'flutter_network_mcp: DB is ${_mb(size)}MB (> ${_mb(cap)}MB cap) but '
          'all remaining data belongs to the attached session(s); cannot evict '
          'live data. Detach to let it be reclaimed, or raise the cap.',
        );
      }
      return result;
    }

    _warnedNothingEvictable = false;
    lastEviction = result.toJson();
    io.stderr.writeln(
      'flutter_network_mcp: DB over cap (${_mb(originalSize)}MB > ${_mb(cap)}MB) '
      '— evicted ${result.bodiesDropped} bodies, ${result.logsDropped} logs, '
      '${result.sessionsDropped} session(s), freed ${_mb(result.bytesFreed)}MB.',
    );
    return result;
  }

  static String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);
}
