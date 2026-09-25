import 'dart:io' as io;

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

  /// Alert retention window in DAYS. Alerts from non-attached (ended /
  /// interrupted) sessions older than this are auto-expired by
  /// [AlertRetention], so the pending banner reflects recent state instead
  /// of months of accumulated noise. 0 disables retention (keep forever).
  /// Initial value from FLUTTER_NETWORK_MCP_ALERT_RETENTION_DAYS (default
  /// 14); runtime-tunable via `alerts_config set:{retentionDays:N}`.
  int alertRetentionDays = _envRetentionDays();

  static int _envRetentionDays() {
    final raw = _env('FLUTTER_NETWORK_MCP_ALERT_RETENTION_DAYS');
    final parsed = raw == null ? null : int.tryParse(raw.trim());
    if (parsed == null || parsed < 0) return 14;
    return parsed;
  }

  static String? _env(String key) {
    try {
      return io.Platform.environment[key];
    } catch (_) {
      return null;
    }
  }

  bool http5xxEnabled = true;
  bool http4xxEnabled = true;
  bool httpErrorEnabled = true;
  bool httpSlowEnabled = true;
  bool logKeywordEnabled = true;
  bool flutterErrorEnabled = true;

  /// 0.7.3: baseline-relative anomaly detection on HTTP endpoints. Fires
  /// `http_anomaly` (latency) and `http_anomaly_errors` (error rate) when
  /// current behavior diverges from the established baseline. See
  /// `AnomalyDetector` for thresholds.
  bool anomalyEnabled = true;

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

  /// The canonical rule-key list. alerts_config derives its input schema,
  /// toggle handling, and enabled-count from THIS (via [toJson]) so the
  /// schema can never drift from the real rule set again (audit F13: the
  /// tool advertised 6 keys and reported "6/6" while 7 rules existed and
  /// http_anomaly was untoggleable).
  static const List<String> ruleKeys = [
    'http_5xx',
    'http_4xx',
    'http_error',
    'http_slow',
    'log_keyword',
    'flutter_error',
    'http_anomaly',
  ];

  Map<String, Object?> toJson() => {
        'slowThresholdMs': slowThresholdMs,
        'retentionDays': alertRetentionDays,
        'rules': {
          'http_5xx': http5xxEnabled,
          'http_4xx': http4xxEnabled,
          'http_error': httpErrorEnabled,
          'http_slow': httpSlowEnabled,
          'log_keyword': logKeywordEnabled,
          'flutter_error': flutterErrorEnabled,
          'http_anomaly': anomalyEnabled,
        },
      };

  void applyConfig({
    int? slowThresholdMs,
    int? retentionDays,
    Map<String, dynamic>? rules,
  }) {
    if (slowThresholdMs != null && slowThresholdMs > 0) {
      this.slowThresholdMs = slowThresholdMs;
    }
    // retentionDays: >=0 accepted (0 disables); negative ignored.
    if (retentionDays != null && retentionDays >= 0) {
      alertRetentionDays = retentionDays;
    }
    if (rules != null) {
      http5xxEnabled = (rules['http_5xx'] as bool?) ?? http5xxEnabled;
      http4xxEnabled = (rules['http_4xx'] as bool?) ?? http4xxEnabled;
      httpErrorEnabled = (rules['http_error'] as bool?) ?? httpErrorEnabled;
      httpSlowEnabled = (rules['http_slow'] as bool?) ?? httpSlowEnabled;
      logKeywordEnabled = (rules['log_keyword'] as bool?) ?? logKeywordEnabled;
      flutterErrorEnabled =
          (rules['flutter_error'] as bool?) ?? flutterErrorEnabled;
      anomalyEnabled = (rules['http_anomaly'] as bool?) ?? anomalyEnabled;
    }
  }
}
