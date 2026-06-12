import 'dart:async';
import 'dart:io' as io;

import 'state/session.dart';
import 'tools/network_attach.dart' show appSessionIdentity, performAttach;
import 'vm/dtd_probe.dart';

/// One planned hot-restart migration: the dead session [priorSessionId] (last
/// bound to [priorUri]) should reattach to [newUri], which is now serving the
/// same logical app [identity].
class MigrationPlan {
  const MigrationPlan({
    required this.priorSessionId,
    required this.priorUri,
    required this.newUri,
    required this.identity,
  });

  final int priorSessionId;
  final String priorUri;
  final String newUri;
  final String identity;
}

/// Decides which attached sessions should migrate, given the current set of
/// attached sessions and the live `uri -> appName` map from DTD. Pure +
/// visible for testing: the watcher does the IO, this does the matching.
///
/// A session migrates only when ALL hold, which is what keeps it safe:
/// - its own URI is no longer live (the app behind it is gone / restarted),
/// - exactly ONE live URI serves the same logical app identity
///   ([appSessionIdentity], package+device),
/// - that URI is not already attached and not already claimed by another plan.
///
/// Ambiguous cases (zero or multiple candidates) are skipped, never guessed,
/// so a session is never migrated onto the wrong app.
List<MigrationPlan> planMigrations({
  required List<({int id, String uri, String? appName})> attached,
  required Map<String, String> liveByUri,
}) {
  final liveUris = liveByUri.keys.toSet();
  final attachedUris = {for (final a in attached) a.uri};
  final claimed = <String>{};
  final plans = <MigrationPlan>[];

  for (final s in attached) {
    if (liveUris.contains(s.uri)) continue; // still alive, nothing to do
    final identity = appSessionIdentity(s.appName);
    if (identity == null) continue;

    final candidates = [
      for (final e in liveByUri.entries)
        if (e.key != s.uri &&
            !attachedUris.contains(e.key) &&
            !claimed.contains(e.key) &&
            appSessionIdentity(e.value) == identity)
          e.key,
    ];
    if (candidates.length != 1) continue; // 0 = not back yet, >1 = ambiguous

    claimed.add(candidates.first);
    plans.add(MigrationPlan(
      priorSessionId: s.id,
      priorUri: s.uri,
      newUri: candidates.first,
      identity: identity,
    ));
  }
  return plans;
}

/// Background watcher that keeps a session id stable across a hot restart for
/// ANY attached app (issue #16), without the agent calling
/// `network_attach reattach:true` by hand.
///
/// Each tick polls DTD, finds attached sessions whose VM URI has gone away,
/// and reattaches the SAME session id to the app's new URI when exactly one
/// live URI matches its identity. Migration reuses the already-tested
/// `performAttach(reattach:true)` path (repoint the DB row, restart capture,
/// drop the stale session), so this class only decides WHEN.
///
/// Opt out with `FLUTTER_NETWORK_MCP_NO_AUTO_MIGRATE=true`. Poll interval:
/// `FLUTTER_NETWORK_MCP_MIGRATE_POLL_MS` (1000-60000, default 5000).
class SessionMigrator {
  SessionMigrator({this.defaultDtdUri, Duration? pollInterval})
      : pollInterval = pollInterval ?? _envPollInterval();

  static Duration _envPollInterval() {
    final raw =
        io.Platform.environment['FLUTTER_NETWORK_MCP_MIGRATE_POLL_MS'];
    final parsed = raw == null ? null : int.tryParse(raw);
    if (parsed == null) return const Duration(seconds: 5);
    final clamped = parsed < 1000 ? 1000 : (parsed > 60000 ? 60000 : parsed);
    return Duration(milliseconds: clamped);
  }

  final String? defaultDtdUri;
  final Duration pollInterval;

  Timer? _timer;
  bool _ticking = false;

  bool get isRunning => _timer != null;

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(pollInterval, (_) => _tick());
    io.stderr.writeln(
      'flutter_network_mcp: hot-restart migration watcher started '
      '(poll ${pollInterval.inMilliseconds}ms). Set '
      'FLUTTER_NETWORK_MCP_NO_AUTO_MIGRATE=true to disable.',
    );
    unawaited(_tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    if (_ticking) return; // reentrancy guard
    _ticking = true;
    try {
      await _runTick();
    } catch (e, st) {
      io.stderr.writeln(
        'flutter_network_mcp: migration tick crashed unexpectedly ($e). '
        'Watcher continues polling.\n$st',
      );
    } finally {
      _ticking = false;
    }
  }

  Future<void> _runTick() async {
    final registry = SessionRegistry.instance;
    if (registry.attachedCount == 0) return; // nothing to migrate

    final List<DtdAppListing> listings;
    try {
      listings = await DtdProbe.probeAll();
    } catch (_) {
      return; // discovery read failed; existing attachments keep capturing
    }

    final liveByUri = <String, String>{};
    for (final listing in listings) {
      for (final a in listing.apps) {
        if (a.uri.isEmpty) continue;
        liveByUri.putIfAbsent(a.uri, () => a.name ?? '');
      }
    }

    final attached = [
      for (final s in registry.attached.values)
        (id: s.id, uri: s.vmServiceUri, appName: s.appName),
    ];

    for (final plan in planMigrations(attached: attached, liveByUri: liveByUri)) {
      // Re-check against live registry state (a tick is async; the world may
      // have shifted since planMigrations ran on the snapshot).
      if (registry.attachedByUri(plan.priorUri) == null) continue;
      if (registry.attachedByUri(plan.newUri) != null) continue;
      try {
        final result = await performAttach(
          vmServiceUri: plan.newUri,
          reattach: true,
          defaultDtdUri: defaultDtdUri,
        );
        if (result['error'] != null) {
          io.stderr.writeln(
            'flutter_network_mcp: auto-migrate skipped ${plan.newUri}: '
            '${result['error']}',
          );
        } else if (result['reattached'] == true) {
          io.stderr.writeln(
            'flutter_network_mcp: auto-migrated session '
            '${plan.priorSessionId} (${result['appName'] ?? "app"}) across a '
            'hot restart: ${plan.priorUri} -> ${plan.newUri}.',
          );
        } else {
          // Defensive: a fresh session was created instead of reusing the id
          // (e.g. the new URI's app name could not be resolved for identity
          // matching). Surface it rather than claim a migration.
          io.stderr.writeln(
            'flutter_network_mcp: WARNING reattach to ${plan.newUri} did not '
            'reuse session ${plan.priorSessionId} (got session '
            '${result['liveSessionId']}). The stale session may linger; '
            'network_detach it manually.',
          );
        }
      } catch (e) {
        io.stderr.writeln(
          'flutter_network_mcp: auto-migrate error for ${plan.newUri}: $e',
        );
      }
    }
  }
}
