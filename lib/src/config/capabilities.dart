/// Capability categories. Lifecycle tools (status/attach/detach) are always
/// available and not represented here.
enum Category {
  /// HTTP request tools: list, get, body, clear (search lives separately).
  http('http'),

  /// dart:io socket tools.
  sockets('sockets'),

  /// Log streams + logs_tail / logs_clear.
  logs('logs'),

  /// Alert pipeline + alerts_drain / alerts_peek / alerts_config.
  alerts('alerts'),

  /// Full-text search: network_search.
  search('search'),

  /// Persistent sessions: session_list / open / close / export / note.
  sessions('sessions'),

  /// Read-only SQL escape hatch: network_query.
  sql('sql'),

  /// Admin: ignored_hosts (host allowlist).
  admin('admin');

  const Category(this.key);
  final String key;

  static Category? byKey(String s) {
    for (final c in Category.values) {
      if (c.key == s) return c;
    }
    return null;
  }
}

/// Process-global capability configuration. Set once at startup by
/// [bin/main.dart] before the server is constructed; immutable afterwards.
class CapabilityConfig {
  CapabilityConfig._(this._enabled);

  static CapabilityConfig _instance = CapabilityConfig._(Category.values.toSet());

  static CapabilityConfig get instance => _instance;

  final Set<Category> _enabled;

  bool isEnabled(Category c) => _enabled.contains(c);
  Set<Category> get enabled => Set.unmodifiable(_enabled);

  /// Builds a config from CLI flags. Pass exactly one of `allowlist` or
  /// `denylist` (or neither for the default "all on" config).
  ///
  /// Strings come in comma-separated. Unknown tokens raise [ArgumentError].
  factory CapabilityConfig.fromFlags({String? allowlist, String? denylist}) {
    if (allowlist != null && denylist != null) {
      throw ArgumentError(
        'Pass either --capabilities or --disable, not both.',
      );
    }

    if (allowlist != null && allowlist.isNotEmpty) {
      final set = _parse(allowlist);
      return CapabilityConfig._(set);
    }

    final disabled = denylist != null && denylist.isNotEmpty
        ? _parse(denylist)
        : <Category>{};
    final on = Category.values.toSet()..removeAll(disabled);
    return CapabilityConfig._(on);
  }

  /// Replaces the singleton. Intended for `bin/main.dart` startup.
  static void install(CapabilityConfig config) {
    _instance = config;
  }

  static Set<Category> _parse(String csv) {
    final out = <Category>{};
    for (final raw in csv.split(',')) {
      final tok = raw.trim().toLowerCase();
      if (tok.isEmpty) continue;
      final c = Category.byKey(tok);
      if (c == null) {
        final valid = Category.values.map((c) => c.key).join(', ');
        throw ArgumentError(
          'Unknown capability "$tok". Valid options: $valid.',
        );
      }
      out.add(c);
    }
    return out;
  }
}
