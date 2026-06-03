import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:path/path.dart' as p;

/// Background "is there a newer version?" probe that runs at most once per
/// UTC day. Hits the raw `pubspec.yaml` on `master` (no GitHub API, no
/// rate-limit headaches) and parses the `version:` line. When the upstream
/// version is newer, prints one stderr nudge:
///
/// ```
/// flutter_network_mcp: v0.6.3 available (you're on 0.6.2). Run
/// `flutter_network_mcp update` to upgrade. (Silence with
/// FLUTTER_NETWORK_MCP_NO_UPDATE_CHECK=true.)
/// ```
///
/// All network errors are swallowed silently. Version check is best-effort;
/// it never blocks startup, never crashes the MCP, never delays the JSON-
/// RPC handshake. Fire-and-forget from `main()` after the server starts.
class UpdateCheck {
  static const String _pubspecUrl =
      'https://raw.githubusercontent.com/Lukas-io/flutter_network_mcp/master/pubspec.yaml';

  static const Duration _connectTimeout = Duration(seconds: 3);
  static const Duration _totalTimeout = Duration(seconds: 5);

  /// Fire-and-forget. Caller MUST NOT await this in a path that blocks
  /// startup; use `unawaited(UpdateCheck.maybeCheck(...))`.
  static Future<void> maybeCheck({
    required String currentVersion,
    required String dataDir,
  }) async {
    try {
      // Opt-out: env var skips the whole probe.
      final env = io.Platform.environment;
      if (env['FLUTTER_NETWORK_MCP_NO_UPDATE_CHECK']?.toLowerCase() == 'true') {
        return;
      }

      // Daily cache: skip if we already checked today.
      final cacheFile = io.File(p.join(dataDir, '.update-check'));
      if (_alreadyCheckedToday(cacheFile)) return;

      final upstream = await _fetchUpstreamVersion();
      if (upstream == null) return;

      // Touch the cache even when versions match — we DID check today,
      // no point retrying until tomorrow.
      _touchCache(cacheFile);

      final isNewer = _isNewer(upstream, currentVersion);

      // Write the agent-readable status file alongside the cache.
      // network_status reads this and surfaces `mcp.updateAvailable` so
      // the agent doesn't have to scrape stderr for the nudge.
      _writeStatusFile(
        dataDir: dataDir,
        currentVersion: currentVersion,
        latestVersion: upstream,
        isNewer: isNewer,
      );

      if (isNewer) {
        io.stderr.writeln(
          'flutter_network_mcp: v$upstream available (you\'re on '
          'v$currentVersion). Run `flutter_network_mcp update` to upgrade. '
          '(Silence with FLUTTER_NETWORK_MCP_NO_UPDATE_CHECK=true.)',
        );
      }
    } catch (_) {
      // Best-effort: network errors, parse errors, filesystem failures
      // all stay silent. Version check should never disturb the MCP.
    }
  }

  static bool _alreadyCheckedToday(io.File cacheFile) {
    try {
      if (!cacheFile.existsSync()) return false;
      final raw = cacheFile.readAsStringSync().trim();
      final last = DateTime.tryParse(raw);
      if (last == null) return false;
      final now = DateTime.now().toUtc();
      return last.year == now.year &&
          last.month == now.month &&
          last.day == now.day;
    } catch (_) {
      return false;
    }
  }

  static void _touchCache(io.File cacheFile) {
    try {
      final parent = cacheFile.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      cacheFile.writeAsStringSync(DateTime.now().toUtc().toIso8601String());
    } catch (_) {/* silent */}
  }

  /// Writes `<data-dir>/.update-status.json` so `network_status` can
  /// surface `mcp.updateAvailable` without re-hitting the network. Best-
  /// effort — write failures stay silent.
  static void _writeStatusFile({
    required String dataDir,
    required String currentVersion,
    required String latestVersion,
    required bool isNewer,
  }) {
    try {
      final file = io.File(p.join(dataDir, '.update-status.json'));
      final parent = file.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      final payload = {
        'checkedAtMs': DateTime.now().toUtc().millisecondsSinceEpoch,
        'current': currentVersion,
        'latest': latestVersion,
        'isNewer': isNewer,
        'upgradeCommand': 'flutter_network_mcp update',
      };
      file.writeAsStringSync(jsonEncode(payload));
    } catch (_) {/* silent */}
  }

  /// Best-effort reader for `network_status`. Returns null when the file
  /// is missing / unreadable / stale / malformed.
  static Map<String, Object?>? readStatusFile(String dataDir) {
    try {
      final file = io.File(p.join(dataDir, '.update-status.json'));
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return null;
      return decoded.cast<String, Object?>();
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _fetchUpstreamVersion() async {
    final client = io.HttpClient()
      ..connectionTimeout = _connectTimeout
      ..userAgent = 'flutter_network_mcp-update-check';
    try {
      final request = await client
          .getUrl(Uri.parse(_pubspecUrl))
          .timeout(_connectTimeout);
      final response = await request.close().timeout(_totalTimeout);
      if (response.statusCode != 200) return null;
      final body =
          await response.transform(utf8.decoder).join().timeout(_totalTimeout);
      return _parseVersionLine(body);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Extracts `0.6.3` from a pubspec containing `version: 0.6.3`. Returns
  /// null when no version line is present or the value isn't a recognized
  /// semver triple.
  static String? _parseVersionLine(String yaml) {
    for (final line in const LineSplitter().convert(yaml)) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('version:')) continue;
      final value = trimmed.substring('version:'.length).trim();
      // Strip any quotes the user might add.
      final cleaned = value.replaceAll(RegExp('["\']'), '');
      if (_parseTriple(cleaned) != null) return cleaned;
      return null;
    }
    return null;
  }

  /// True when [upstream] is strictly newer than [current]. Both must be
  /// semver triples (`major.minor.patch`); non-parseable inputs return
  /// false (treat as "not newer" to avoid spurious nudges).
  static bool _isNewer(String upstream, String current) {
    final u = _parseTriple(upstream);
    final c = _parseTriple(current);
    if (u == null || c == null) return false;
    for (var i = 0; i < 3; i++) {
      if (u[i] > c[i]) return true;
      if (u[i] < c[i]) return false;
    }
    return false;
  }

  /// Parses `0.6.3` into `[0, 6, 3]`. Tolerates a `-prerelease` suffix
  /// (strips it) but ignores prerelease ordering — we only compare the
  /// triple. Returns null on malformed input.
  static List<int>? _parseTriple(String version) {
    final base = version.split('-').first;
    final parts = base.split('.');
    if (parts.length != 3) return null;
    final out = <int>[];
    for (final part in parts) {
      final n = int.tryParse(part);
      if (n == null) return null;
      out.add(n);
    }
    return out;
  }
}
