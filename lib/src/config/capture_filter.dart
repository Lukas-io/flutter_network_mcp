import 'dart:io' as io;

/// Decides whether a captured request is persisted (issue #64). Two layers:
///
/// - **Denylist** — the `ignored_hosts` entries. An entry with no `/` matches a
///   whole host (the pre-#64 behavior); an entry containing `/` is a
///   `host/path` glob, so `dev.example.com/socket.io/*` silences just the
///   socket.io polling while the REST API on the same host keeps flowing.
/// - **Allowlist** — opt-in via `FLUTTER_NETWORK_MCP_CAPTURE_ALLOW` (comma-
///   separated patterns). When non-empty, ONLY matching requests are persisted;
///   everything else is dropped. For focused debugging ("just /stock/*").
///
/// A request is captured when: (allowlist empty OR it matches the allowlist)
/// AND it does not match the denylist. Patterns are matched case-insensitively
/// against `host + path` (no scheme, no query).
class CaptureFilter {
  CaptureFilter._(this._deny, this._allow);

  /// An inert filter that captures everything (no deny, no allow).
  factory CaptureFilter.empty() => CaptureFilter._(const [], const []);

  final List<_Pattern> _deny;
  final List<_Pattern> _allow;

  bool get hasAllowlist => _allow.isNotEmpty;
  bool get isActive => _deny.isNotEmpty || _allow.isNotEmpty;

  /// Pattern strings, for surfacing the active filter to the agent.
  List<String> get allowPatterns => [for (final p in _allow) p.raw];

  bool shouldCapture(Uri uri) {
    final host = uri.host.toLowerCase();
    final target = '$host${uri.path}'.toLowerCase();
    if (_allow.isNotEmpty && !_allow.any((p) => p.matches(host, target))) {
      return false;
    }
    if (_deny.any((p) => p.matches(host, target))) return false;
    return true;
  }

  /// Builds from the denylist [denyEntries] (ignored_hosts) and the allowlist
  /// env var. [allowOverride] lets tests inject patterns instead of the env.
  static CaptureFilter build(
    Set<String> denyEntries, {
    List<String>? allowOverride,
  }) {
    final allowRaw = allowOverride ?? _allowFromEnv();
    return CaptureFilter._(
      [for (final e in denyEntries) _Pattern.parse(e)],
      [for (final e in allowRaw) _Pattern.parse(e)],
    );
  }

  static List<String> _allowFromEnv() {
    final raw = io.Platform.environment['FLUTTER_NETWORK_MCP_CAPTURE_ALLOW'];
    if (raw == null || raw.trim().isEmpty) return const [];
    return [
      for (final p in raw.split(','))
        if (p.trim().isNotEmpty) p.trim(),
    ];
  }
}

/// A single host-exact or host/path-glob pattern.
class _Pattern {
  _Pattern._(this.raw, this._hostOnly, this._regex);

  final String raw;
  final String? _hostOnly;
  final RegExp? _regex;

  bool matches(String host, String target) {
    if (_hostOnly != null) return host == _hostOnly;
    return _regex!.hasMatch(target);
  }

  static _Pattern parse(String raw) {
    final p = raw.trim().toLowerCase();
    if (!p.contains('/')) {
      return _Pattern._(raw, p, null);
    }
    return _Pattern._(raw, null, _globToRegExp(p));
  }

  /// Converts a glob (`*` = any chars, `?` = one char) to an anchored RegExp.
  static RegExp _globToRegExp(String glob) {
    final buf = StringBuffer('^');
    for (final ch in glob.split('')) {
      if (ch == '*') {
        buf.write('.*');
      } else if (ch == '?') {
        buf.write('.');
      } else {
        buf.write(RegExp.escape(ch));
      }
    }
    buf.write(r'$');
    return RegExp(buf.toString());
  }
}
