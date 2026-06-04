import 'dart:convert';
import 'dart:io' as io;

import 'package:path/path.dart' as p;

import '../util/data_dir.dart';

/// Process-lifetime singleton holding the resolved auto-attach configuration
/// so non-bin/ tools (specifically `network_attach`) can read the current
/// allowlist without re-parsing CLI flags + env vars themselves.
///
/// **Resolution order (0.7.4+):**
/// 1. Read persistent file `<data-dir>/auto-attach.json` as the BASE.
/// 2. Apply env vars (`FLUTTER_NETWORK_MCP_AUTO_ATTACH`,
///    `FLUTTER_NETWORK_MCP_AUTO_ATTACH_DENY`) as overrides.
/// 3. Apply CLI flags (`--auto-attach`, `--auto-attach-deny`) as final
///    overrides.
///
/// This means the user can persist their default via the agent-callable
/// `auto_attach_config` tool (which writes the file) and still override
/// per-launch via env vars or flags. The `claude mcp remove + add`
/// cycle goes away for the common case.
///
/// Wired from `bin/flutter_network_mcp.dart` once at startup. Empty when
/// auto-attach isn't configured (the common case for first-time users).
/// `network_attach` reads this to decide whether the freshly-attached app
/// is already covered by auto-attach and, if not, surfaces a hint asking
/// the agent to prompt the user about adding it.
class AutoAttachConfig {
  AutoAttachConfig._();

  /// File name for the persisted config under the user's data dir.
  static const String fileName = 'auto-attach.json';

  static List<String> _allowed = const [];
  static List<String> _denied = const [];

  /// Read-only view of the resolved allowlist patterns. Empty when
  /// auto-attach is disabled.
  static List<String> get allowedPatterns => _allowed;

  /// Read-only view of the resolved denylist patterns.
  static List<String> get deniedPatterns => _denied;

  /// True when auto-attach is enabled (allowlist non-empty).
  static bool get isEnabled => _allowed.isNotEmpty;

  /// Wires the resolved config. Called once from `main()` after CLI + env
  /// var resolution. Calling again replaces the prior values — tests may
  /// rely on that.
  static void set({
    required List<String> allowed,
    required List<String> denied,
  }) {
    _allowed = List.unmodifiable(allowed);
    _denied = List.unmodifiable(denied);
  }

  /// True when [appName] case-insensitive contains at least one allowlist
  /// pattern. Mirrors `AutoAttacher._matchesAllowlist` so the in-attach
  /// decision matches what the watcher would do.
  static bool matchesAllowlist(String appName) {
    if (appName.isEmpty) return false;
    if (_allowed.isEmpty) return false;
    final lower = appName.toLowerCase();
    for (final pattern in _allowed) {
      if (pattern.isEmpty) continue;
      if (lower.contains(pattern.toLowerCase())) return true;
    }
    return false;
  }

  /// Loads the persisted config from `<data-dir>/auto-attach.json` and
  /// returns the (allowed, denied) tuple. Empty lists when the file
  /// doesn't exist OR is malformed. Used by `bin/` as the BASE before
  /// env-var / CLI overrides.
  static ({List<String> allowed, List<String> denied}) loadFromFile() {
    try {
      final dataDir = resolveCandidateDataDir();
      if (dataDir == null) {
        return (allowed: const [], denied: const []);
      }
      final file = io.File(p.join(dataDir, fileName));
      if (!file.existsSync()) {
        return (allowed: const [], denied: const []);
      }
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) {
        return (allowed: const [], denied: const []);
      }
      final allowed = _readStringList(decoded['allowed']);
      final denied = _readStringList(decoded['denied']);
      return (allowed: allowed, denied: denied);
    } catch (_) {
      return (allowed: const [], denied: const []);
    }
  }

  /// Writes the current config to `<data-dir>/auto-attach.json`. Used by
  /// the `auto_attach_config` tool when the agent adds or removes an
  /// app. Best-effort — failures stay silent so a transient FS hiccup
  /// doesn't break the tool response. Returns true on successful write.
  static bool writeToFile() {
    try {
      final dataDir = resolveCandidateDataDir();
      if (dataDir == null) return false;
      final dir = io.Directory(dataDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final payload = <String, Object?>{
        'allowed': _allowed,
        'denied': _denied,
        'writtenAtMs': DateTime.now().millisecondsSinceEpoch,
      };
      io.File(p.join(dataDir, fileName)).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(payload),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Path used by `writeToFile` / `loadFromFile`. Returns null when the
  /// data dir can't be resolved (no `$HOME`).
  static String? filePath() {
    final dataDir = resolveCandidateDataDir();
    if (dataDir == null) return null;
    return p.join(dataDir, fileName);
  }

  static List<String> _readStringList(Object? raw) {
    if (raw is! List) return const [];
    final out = <String>[];
    for (final v in raw) {
      if (v is String && v.isNotEmpty) out.add(v);
    }
    return out;
  }
}
