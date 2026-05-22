/// A single custom alert pattern loaded from the `alert_patterns` table.
class CustomPattern {
  CustomPattern({
    required this.id,
    required this.kind,
    required this.regex,
    required this.severity,
    this.label,
  });
  final int id;
  final String kind;
  final RegExp regex;
  final String severity;
  final String? label;
}

/// Tunable rule set for the alert detector. Singleton; mutated by
/// `alerts_config` at runtime.
class AlertRules {
  AlertRules._();
  static final AlertRules instance = AlertRules._();

  /// Custom user-defined regex patterns, refreshed from the DB by
  /// `refreshCustomPatterns()` on add/remove.
  List<CustomPattern> customPatterns = const [];

  int slowThresholdMs = 3000;

  bool http5xxEnabled = true;
  bool http4xxEnabled = true;
  bool httpErrorEnabled = true;
  bool httpSlowEnabled = true;
  bool logKeywordEnabled = true;
  bool flutterErrorEnabled = true;

  /// Generic error-keyword regex used against log messages.
  static final logKeywordRegex = RegExp(
    r'error|exception|failed|denied|timeout|refused|crash',
    caseSensitive: false,
  );

  /// Flutter / Dart framework error patterns. Multi-line so they survive
  /// pretty-printed exception dumps.
  static final flutterErrorPatterns = <RegExp>[
    RegExp(r'FlutterError|EXCEPTION CAUGHT BY|═+.*EXCEPTION', multiLine: true),
    RegExp(r'RenderFlex overflowed|RenderBox.*overflowed', multiLine: true),
    RegExp(r'Null check operator used on a null value', multiLine: true),
    RegExp(r'setState\(\) called after dispose', multiLine: true),
    RegExp(r'Bad state:', multiLine: true),
    RegExp(r"type '.+' is not a subtype of", multiLine: true),
    RegExp(r'^#0\s+', multiLine: true),
    RegExp(
      r'ProviderNotFoundException|UnimplementedError|UnsupportedError',
      multiLine: true,
    ),
  ];

  Map<String, Object?> toJson() => {
        'slowThresholdMs': slowThresholdMs,
        'rules': {
          'http_5xx': http5xxEnabled,
          'http_4xx': http4xxEnabled,
          'http_error': httpErrorEnabled,
          'http_slow': httpSlowEnabled,
          'log_keyword': logKeywordEnabled,
          'flutter_error': flutterErrorEnabled,
        },
      };

  void applyConfig({
    int? slowThresholdMs,
    Map<String, dynamic>? rules,
  }) {
    if (slowThresholdMs != null && slowThresholdMs > 0) {
      this.slowThresholdMs = slowThresholdMs;
    }
    if (rules != null) {
      http5xxEnabled = (rules['http_5xx'] as bool?) ?? http5xxEnabled;
      http4xxEnabled = (rules['http_4xx'] as bool?) ?? http4xxEnabled;
      httpErrorEnabled = (rules['http_error'] as bool?) ?? httpErrorEnabled;
      httpSlowEnabled = (rules['http_slow'] as bool?) ?? httpSlowEnabled;
      logKeywordEnabled = (rules['log_keyword'] as bool?) ?? logKeywordEnabled;
      flutterErrorEnabled =
          (rules['flutter_error'] as bool?) ?? flutterErrorEnabled;
    }
  }
}
