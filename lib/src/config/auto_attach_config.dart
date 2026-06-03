/// Process-lifetime singleton holding the resolved auto-attach configuration
/// so non-bin/ tools (specifically `network_attach`) can read the current
/// allowlist without re-parsing CLI flags + env vars themselves.
///
/// Wired from `bin/flutter_network_mcp.dart` once at startup. Empty when
/// auto-attach isn't configured (the common case for first-time users).
/// `network_attach` reads this to decide whether the freshly-attached app
/// is already covered by auto-attach and, if not, surfaces a hint asking
/// the agent to prompt the user about adding it.
class AutoAttachConfig {
  AutoAttachConfig._();

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
}
