import 'dart:async';
import 'dart:io' as io;

import 'state/session.dart';
import 'tools/network_attach.dart' show performAttach;
import 'vm/dtd_probe.dart';

/// Background watcher that polls DTD periodically for new VM service URIs
/// and auto-attaches to apps that appear AFTER the watcher started.
///
/// **Mandatory allowlist:** every constructor call must pass a non-empty
/// [allowedAppPatterns] list. Each pattern is a case-insensitive
/// substring matched against the DTD app name (e.g. "sanga_mobile"
/// matches "Flutter - iPhone 17 - Package: sanga_mobile"). The CLI
/// surface (`--auto-attach=app1,app2`) has no boolean form — you can't
/// enable auto-attach without saying which apps it's allowed to grab.
///
/// **Optional denylist** ([deniedAppPatterns]) lets you exclude specific
/// devices that would otherwise match the allowlist — useful when the
/// allowlist is a broad package name but you want to skip a particular
/// device (`--auto-attach=sanga_mobile --auto-attach-deny="Pixel 7"`).
/// Same case-insensitive substring matching as the allowlist. Deny wins
/// when both match.
///
/// Non-matching apps (allowlist miss OR denylist hit) log a one-line
/// stderr note + are added to the known-URI set so they don't retry
/// every tick (acts as both rate-limit and audit trail).
///
/// Existing apps visible at startup ARE auto-attached when they match the
/// allowlist (0.6.2 change — the allowlist is the explicit opt-in, no need
/// to also wait for a Flutter restart). On the first tick, every running
/// app goes through the same allowlist + denylist gate as later ticks; the
/// `_seenUris` set still de-dupes so each URI is attached at most once.
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
    required this.allowedAppPatterns,
    this.deniedAppPatterns = const [],
    Duration? pollInterval,
  })  : assert(
          allowedAppPatterns.isNotEmpty,
          'allowedAppPatterns must be non-empty — auto-attach requires '
          'an explicit allowlist of app substrings.',
        ),
        pollInterval = pollInterval ?? _envPollInterval();

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

  /// Case-insensitive substring patterns matched against the DTD app name.
  /// Required + non-empty by constructor assertion. At least one pattern
  /// must match an app's name for that app to be auto-attached.
  final List<String> allowedAppPatterns;

  /// Optional denylist: case-insensitive substring patterns. If any
  /// pattern matches, the app is skipped even when the allowlist would
  /// otherwise admit it. Empty by default. Deny wins over allow.
  final List<String> deniedAppPatterns;

  final Duration pollInterval;
  Timer? _timer;
  final Set<String> _seenUris = {};
  bool _seedComplete = false;

  /// Reentrancy guard. `Timer.periodic` fires regardless of whether the
  /// previous tick's Future completed; without this, two concurrent ticks
  /// could race on _seenUris + double-issue performAttach.
  bool _ticking = false;

  /// Cap on the known-URI set so pathological vmServiceUri churn (a
  /// hot-restart loop, say) can't grow memory unbounded.
  static const int _seenUrisCap = 1024;

  bool get isRunning => _timer != null;

  /// Starts the polling watcher. No-op if [defaultDtdUri] is null (we have
  /// nothing to poll). Fires the first tick immediately so allowlisted
  /// already-running apps attach without waiting `pollInterval`.
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
    final denyLine = deniedAppPatterns.isEmpty
        ? ''
        : '; denylist: ${deniedAppPatterns.join(", ")}';
    io.stderr.writeln(
      'flutter_network_mcp: auto-attach watcher started '
      '(poll ${pollInterval.inMilliseconds}ms; allowlist: '
      '${allowedAppPatterns.join(", ")}$denyLine; allowlisted apps already '
      'running attach on the first tick).',
    );
    unawaited(_tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Returns true when [appName] is matched by at least one allowlist
  /// pattern (case-insensitive substring). Empty app names never match.
  bool _matchesAllowlist(String appName) {
    if (appName.isEmpty) return false;
    final lower = appName.toLowerCase();
    for (final pattern in allowedAppPatterns) {
      if (pattern.isEmpty) continue;
      if (lower.contains(pattern.toLowerCase())) return true;
    }
    return false;
  }

  /// Returns true when [appName] matches any denylist pattern. Empty
  /// denylist (the default) always returns false — no filtering. Empty
  /// app names also never match (consistent with allowlist semantics).
  bool _matchesDenylist(String appName) {
    if (deniedAppPatterns.isEmpty) return false;
    if (appName.isEmpty) return false;
    final lower = appName.toLowerCase();
    for (final pattern in deniedAppPatterns) {
      if (pattern.isEmpty) continue;
      if (lower.contains(pattern.toLowerCase())) return true;
    }
    return false;
  }

  Future<void> _tick() async {
    if (_ticking) return; // Re-entrancy guard.
    _ticking = true;
    // Defense-in-depth: top-level try/catch so an unexpected throw
    // (ConcurrentModificationError on _seenUris, a stack underflow from
    // some upstream API, anything) never escapes the Timer callback.
    // Timer.periodic swallows callback exceptions into the zone, but
    // explicit handling keeps the watcher running even when one tick
    // blows up.
    try {
      await _runTick();
    } catch (e, st) {
      io.stderr.writeln(
        'flutter_network_mcp: auto-attach tick crashed unexpectedly '
        '($e). Watcher continues polling.\n$st',
      );
    } finally {
      _ticking = false;
    }
  }

  Future<void> _runTick() async {
    // Multi-DTD aware in 0.6.2. Each `flutter run` spawns its own DTD;
    // DtdProbe.probeAll opens TRANSIENT clients across every live DTD on
    // the machine and aggregates the app list. The primary
    // `Session.instance.dtd` is left untouched — cross-DTD attaches go
    // via `performAttach(vmServiceUri: ...)` which bypasses DTD entirely.
    final List<DtdAppListing> listings;
    try {
      listings = await DtdProbe.probeAll();
    } catch (_) {
      // Discovery filesystem read failed — silently skip this tick. The
      // primary DTD (if connected) keeps capturing on its existing
      // attachments; we just don't pick up new ones this tick.
      return;
    }

    // Map uri → name across ALL DTDs. De-duped by uri (same vmService
    // shouldn't surface from two DTDs but defend anyway).
    final currentByUri = <String, String>{};
    for (final listing in listings) {
      for (final a in listing.apps) {
        if (a.uri.isEmpty) continue;
        // First listing wins on duplicate — order is discovery rank.
        currentByUri.putIfAbsent(a.uri, () => a.name ?? '');
      }
    }
    final currentUris = currentByUri.keys.toSet();

    // First tick: log intent then fall through. 0.6.2 dropped the old
    // "seed without attaching" behaviour — the allowlist is the explicit
    // opt-in, so allowlisted apps already running should attach now, not
    // wait for the user to flutter-restart.
    final isFirstTick = !_seedComplete;
    _seedComplete = true;
    if (isFirstTick && currentUris.isNotEmpty) {
      io.stderr.writeln(
        'flutter_network_mcp: auto-attach first tick — evaluating '
        '${currentUris.length} currently-running app(s) against allowlist '
        '${allowedAppPatterns.join(", ")}. Matching apps attach immediately.',
      );
    }

    final newUris = currentUris.difference(_seenUris);
    _seenUris.addAll(currentUris);
    _enforceSeenUrisCap();

    for (final uri in newUris) {
      final appName = currentByUri[uri] ?? '';
      final displayName = appName.isEmpty ? '(unnamed)' : appName;

      // Allowlist gate — the security-critical check. Non-matching apps
      // log + are skipped; they stay in _seenUris so we don't retry
      // every tick (acts as both rate-limit and audit trail).
      if (!_matchesAllowlist(appName)) {
        io.stderr.writeln(
          'flutter_network_mcp: auto-attach skipped $uri '
          '(app "$displayName") — no allowlist pattern matched. '
          'Allowlist: ${allowedAppPatterns.join(", ")}.',
        );
        continue;
      }

      // Denylist gate — wins over allowlist. Logged with the specific
      // matched pattern (best-effort) so the user sees why a normally-
      // allowed app got blocked.
      if (_matchesDenylist(appName)) {
        io.stderr.writeln(
          'flutter_network_mcp: auto-attach skipped $uri '
          '(app "$displayName") — denylist matched. Denylist: '
          '${deniedAppPatterns.join(", ")}.',
        );
        continue;
      }

      // Defensive: skip if already attached (race between this tick and
      // a manual network_attach the agent just fired).
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

  /// Bounds _seenUris at [_seenUrisCap]. If we'd exceed, drop the older
  /// half — the safe failure mode is that an old vmServiceUri might be
  /// auto-attached again on a future tick, which performAttach's
  /// per-URI duplicate guard catches if the URI is somehow still alive.
  void _enforceSeenUrisCap() {
    if (_seenUris.length <= _seenUrisCap) return;
    final asList = _seenUris.toList();
    _seenUris
      ..clear()
      ..addAll(asList.sublist(asList.length ~/ 2));
    io.stderr.writeln(
      'flutter_network_mcp: auto-attach known-URI set hit cap '
      '($_seenUrisCap); pruned to ${_seenUris.length}. Pathological '
      'vmServiceUri churn? File an issue.',
    );
  }
}
