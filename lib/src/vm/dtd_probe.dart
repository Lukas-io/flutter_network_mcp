import 'dart:async';
import 'dart:io' as io;

import 'package:dtd/dtd.dart';

import 'dtd_client.dart';
import 'dtd_discovery.dart';

/// One DTD's worth of `getConnectedApps()` output, paired with the source
/// DTD metadata so the agent can tell which `flutter run` produced which
/// app.
class DtdAppListing {
  DtdAppListing({
    required this.dtdUri,
    required this.pid,
    this.workspaceRoot,
    this.ideName,
    this.apps = const [],
    this.error,
  });

  final Uri dtdUri;
  final int pid;
  final String? workspaceRoot;
  final String? ideName;

  /// Apps the source DTD reported. Empty when the probe errored — see
  /// [error]. Each `VmServiceInfo` exposes `uri`, optional `name`, and
  /// optional `exposedUri` from `package:dtd`.
  final List<VmServiceInfo> apps;

  /// Non-null when the transient connect/getConnectedApps failed. The
  /// listing is still surfaced (so the agent sees the DTD exists) but
  /// `apps` is empty.
  final String? error;

  Map<String, Object?> toJson() => {
        'dtdUri': dtdUri.toString(),
        'pid': pid,
        if (workspaceRoot != null) 'workspaceRoot': workspaceRoot,
        if (ideName != null) 'ideName': ideName,
        'apps': [
          for (final a in apps)
            {
              'name': a.name,
              'uri': a.uri,
              if (a.exposedUri != null) 'exposedUri': a.exposedUri,
            },
        ],
        if (error != null) 'error': error,
      };
}

/// Enumerates apps across EVERY live DTD on the local machine — not just
/// the one the primary `Session.instance.dtd` is connected to.
///
/// Each `flutter run` spawns its own DTD; before 0.6.2 the MCP saw only
/// the apps under the primary DTD. With this probe, `network_status` and
/// the auto-attach watcher see ALL apps across ALL DTDs and the agent can
/// pick which to attach to.
///
/// Implementation: opens a TRANSIENT `DtdClient` per discovered DTD,
/// fetches the app list, disconnects. Never touches `Session.instance.dtd`.
/// Parallel via `Future.wait` with a per-probe timeout so one hung DTD
/// can't block the others.
class DtdProbe {
  /// Per-probe deadline. DTD's WebSocket handshake usually completes in
  /// <100ms on localhost; 1.5s is generous enough to absorb the occasional
  /// hiccup without making `network_status` sluggish.
  static const Duration _probeTimeout = Duration(milliseconds: 1500);

  /// Last result + when it was computed. Cleared if [cacheTtl] elapsed
  /// since [_cachedAt], or the discovery-key (sorted pid:epoch tuples)
  /// changed since the cached probe.
  static List<DtdAppListing>? _cached;
  static String? _cachedKey;
  static DateTime? _cachedAt;

  /// Returns one [DtdAppListing] per live DTD found via [DtdDiscovery].
  /// Cached for [cacheTtl] (default 30s) keyed by the set of
  /// `(pid, epoch)` tuples — so back-to-back `network_status` calls don't
  /// hammer every DTD. The cache is invalidated when a new DTD appears
  /// or an old one dies (the discovery key changes).
  static Future<List<DtdAppListing>> probeAll({
    Duration cacheTtl = const Duration(seconds: 30),
  }) async {
    // Discover with cwd:null so we see every DTD, not just the one
    // matching the server's cwd. The agent can filter on workspaceRoot
    // itself if it wants.
    final candidates = DtdDiscovery.discover(cwd: null)
        .where((c) => c.isLive)
        .toList();

    final key = _buildKey(candidates);
    final now = DateTime.now();
    final cached = _cached;
    final cachedKey = _cachedKey;
    final cachedAt = _cachedAt;
    if (cached != null &&
        cachedKey == key &&
        cachedAt != null &&
        now.difference(cachedAt) < cacheTtl) {
      return cached;
    }

    final futures = [for (final c in candidates) _probeOne(c)];
    final results = await Future.wait(futures);

    _cached = results;
    _cachedKey = key;
    _cachedAt = now;
    return results;
  }

  /// Drops the cache. Tests + the `update` subcommand call this; regular
  /// callers should let [cacheTtl] manage staleness.
  static void invalidateCache() {
    _cached = null;
    _cachedKey = null;
    _cachedAt = null;
  }

  static String _buildKey(List<DtdCandidate> candidates) {
    final pairs = candidates
        .map((c) => '${c.pid}:${c.epoch.millisecondsSinceEpoch}')
        .toList()
      ..sort();
    return pairs.join('|');
  }

  static Future<DtdAppListing> _probeOne(DtdCandidate c) async {
    final client = DtdClient();
    try {
      await client.connect(Uri.parse(c.wsUri)).timeout(_probeTimeout);
      final apps = await client.getConnectedApps().timeout(_probeTimeout);
      return DtdAppListing(
        dtdUri: Uri.parse(c.wsUri),
        pid: c.pid,
        workspaceRoot: c.workspaceRoot,
        ideName: c.ideName,
        apps: apps,
      );
    } catch (e) {
      return DtdAppListing(
        dtdUri: Uri.parse(c.wsUri),
        pid: c.pid,
        workspaceRoot: c.workspaceRoot,
        ideName: c.ideName,
        error: e.toString(),
      );
    } finally {
      // Best-effort disconnect; if the connect itself failed there's
      // nothing to close, and DtdClient.disconnect handles the null case.
      try {
        await client.disconnect();
      } catch (e) {
        io.stderr.writeln(
          'flutter_network_mcp: DtdProbe disconnect failed for ${c.wsUri} '
          '($e). Probe result unaffected.',
        );
      }
    }
  }
}
