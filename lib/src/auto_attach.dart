import 'dart:async';
import 'dart:io' as io;

import 'state/session.dart';
import 'tools/network_attach.dart' show performAttach;

/// Background watcher that polls DTD periodically for new VM service URIs
/// and auto-attaches to apps that appear AFTER the watcher started.
///
/// Existing apps visible at startup are NOT auto-attached — they're seeded
/// into the "known" set on the first tick. This avoids surprise-attaching
/// to whatever was already running when the user enabled the flag, and
/// matches the principle of explicit-first behaviour (no silent grab of
/// state the user didn't ask for).
///
/// Manual `network_detach` survives auto-attach: a detached app's URI
/// stays in the known set, so the next poll tick won't re-attach it.
/// Only a NEW vmServiceUri — typically from a fresh `flutter run` or a
/// hot-restart that spawns a new DDS — triggers auto-attach.
///
/// Respects [FLUTTER_NETWORK_MCP_MAX_ATTACH] via `performAttach`'s own
/// cap check; over-cap discoveries log a one-line stderr note and stay
/// in the known set (won't keep retrying every tick).
class AutoAttacher {
  AutoAttacher({
    required this.defaultDtdUri,
    Duration? pollInterval,
  }) : pollInterval = pollInterval ?? _envPollInterval();

  /// Reads `FLUTTER_NETWORK_MCP_AUTO_ATTACH_POLL_MS` (1000–60000).
  /// Default 5000ms.
  static Duration _envPollInterval() {
    final raw =
        io.Platform.environment['FLUTTER_NETWORK_MCP_AUTO_ATTACH_POLL_MS'];
    final parsed = raw == null ? null : int.tryParse(raw);
    if (parsed == null) return const Duration(seconds: 5);
    final clamped =
        parsed < 1000 ? 1000 : (parsed > 60000 ? 60000 : parsed);
    return Duration(milliseconds: clamped);
  }

  final String? defaultDtdUri;
  final Duration pollInterval;
  Timer? _timer;
  final Set<String> _seenUris = {};
  bool _seedComplete = false;

  bool get isRunning => _timer != null;

  /// Starts the polling watcher. No-op if [defaultDtdUri] is null (we have
  /// nothing to poll). Fires the first tick immediately so the seed phase
  /// doesn't wait `pollInterval`.
  void start() {
    if (defaultDtdUri == null) {
      io.stderr.writeln(
        'flutter_network_mcp: --auto-attach skipped — no --dtd-uri / '
        'FLUTTER_NETWORK_MCP_DTD_URI configured.',
      );
      return;
    }
    if (_timer != null) return;
    _timer = Timer.periodic(pollInterval, (_) => _tick());
    io.stderr.writeln(
      'flutter_network_mcp: auto-attach watcher started '
      '(poll ${pollInterval.inMilliseconds}ms; first tick seeds the known '
      'set, subsequent ticks attach to NEW apps only).',
    );
    unawaited(_tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    final dtd = SessionRegistry.instance.dtd;

    // Ensure DTD is connected. Don't disturb an existing connection —
    // DtdClient.connect() disconnects-then-reconnects, which would break
    // any attached session's DTD-derived state.
    if (!dtd.isConnected) {
      try {
        await dtd.connect(Uri.parse(defaultDtdUri!));
      } catch (_) {
        // DTD might be down between polls — silently skip this tick.
        return;
      }
    }

    final List<dynamic> apps;
    try {
      apps = await dtd.getConnectedApps();
    } catch (_) {
      return;
    }

    final currentUris = <String>{
      for (final a in apps) (a.uri as String?) ?? '',
    }..removeWhere((u) => u.isEmpty);

    // First tick: seed the known set without attaching. Apps that were
    // already running when the watcher started are NOT auto-grabbed.
    if (!_seedComplete) {
      _seenUris.addAll(currentUris);
      _seedComplete = true;
      if (currentUris.isNotEmpty) {
        io.stderr.writeln(
          'flutter_network_mcp: auto-attach seeded with ${currentUris.length} '
          'existing app(s); will attach to NEW apps that appear after this.',
        );
      }
      return;
    }

    final newUris = currentUris.difference(_seenUris);
    _seenUris.addAll(currentUris);

    for (final uri in newUris) {
      // Defensive: skip if already attached (race condition between this
      // tick and a manual network_attach the agent just fired).
      if (SessionRegistry.instance.attachedByUri(uri) != null) continue;

      try {
        final result = await performAttach(
          vmServiceUri: uri,
          defaultDtdUri: defaultDtdUri,
        );
        if (result['error'] != null) {
          io.stderr.writeln(
            'flutter_network_mcp: auto-attach skipped $uri — '
            '${result['error']}',
          );
        } else {
          io.stderr.writeln(
            'flutter_network_mcp: auto-attached to '
            '${result['appName'] ?? "app"} '
            '(session ${result['liveSessionId']}).',
          );
        }
      } catch (e) {
        io.stderr.writeln(
          'flutter_network_mcp: auto-attach error for $uri: $e',
        );
      }
    }
  }
}
