import 'dart:io' as io;

/// Rolling DB size cap (issue #58). Default ON at ~2 GB; once `captures.db`
/// exceeds the cap a low-frequency watchdog evicts the OLDEST data first
/// (bodies, then logs, then whole sessions) so recent captures are always
/// kept and disk never creeps unbounded.
///
/// Configure with `FLUTTER_NETWORK_MCP_MAX_DB_BYTES`:
/// - a byte count (e.g. `2147483648`) sets the cap,
/// - `0` / `off` / `false` / `disabled` turns it off,
/// - unset / unparseable falls back to the 2 GB default.
/// A 1 MB floor guards against a pathological tiny cap that would thrash.
class DbCapConfig {
  static const int defaultMaxBytes = 2 * 1024 * 1024 * 1024;
  static const int _floorBytes = 1024 * 1024;

  /// The cap in bytes, or null when eviction is disabled.
  static final int? maxBytes = _read(
    io.Platform.environment['FLUTTER_NETWORK_MCP_MAX_DB_BYTES'],
  );

  static bool get enabled => maxBytes != null;

  /// Pure parser, visible for testing.
  static int? _read(String? raw) {
    if (raw == null || raw.trim().isEmpty) return defaultMaxBytes;
    final t = raw.trim().toLowerCase();
    if (t == '0' || t == 'off' || t == 'false' || t == 'disabled' || t == 'no') {
      return null;
    }
    final n = int.tryParse(t);
    if (n == null || n <= 0) return defaultMaxBytes;
    return n < _floorBytes ? _floorBytes : n;
  }

  static int? readForTest(String? raw) => _read(raw);
}
