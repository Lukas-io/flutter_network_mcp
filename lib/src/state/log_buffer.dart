import 'dart:collection';
import 'dart:io' as io;

/// One captured log record from the VM service Logging/Stdout/Stderr streams.
class LogEntry {
  LogEntry({
    required this.id,
    required this.source,
    required this.timestampMs,
    this.level,
    this.loggerName,
    required this.message,
    this.error,
    this.stackTrace,
    this.isolateId,
  });

  /// Monotonically increasing local id (the cursor used by `logs_tail`).
  final int id;

  /// `logging`, `stdout`, or `stderr`.
  final String source;

  /// Milliseconds since epoch. For Logging records, this is the LogRecord
  /// `time`; for Stdout/Stderr, the Event `timestamp`.
  final int timestampMs;

  /// `package:logging` severity (0–2000) for Logging entries; null otherwise.
  final int? level;
  final String? loggerName;

  final String message;
  final String? error;
  final String? stackTrace;

  /// VM service isolate id (e.g. `isolates/1234567890`) when the event
  /// carried one. Null when the event was VM-level (no isolate context).
  /// Added in Phase 10 for multi-isolate filtering.
  final String? isolateId;
}

/// Bounded FIFO log buffer.
class LogBuffer {
  LogBuffer({int? capacity}) : capacity = capacity ?? _envCapacity();

  /// Reads `FLUTTER_NETWORK_MCP_LOG_BUFFER` (alias:
  /// `FLUTTER_NETWORK_MCP_LOG_BUFFER_SIZE`), clamped 50–10000. Default 500.
  static int _envCapacity() {
    final env = io.Platform.environment;
    final raw = env['FLUTTER_NETWORK_MCP_LOG_BUFFER'] ??
        env['FLUTTER_NETWORK_MCP_LOG_BUFFER_SIZE'];
    final parsed = raw == null ? null : int.tryParse(raw);
    if (parsed == null) return 500;
    if (parsed < 50) return 50;
    if (parsed > 10000) return 10000;
    return parsed;
  }

  final int capacity;
  final Queue<LogEntry> _entries = Queue<LogEntry>();
  int _nextId = 1;

  int get length => _entries.length;

  LogEntry push({
    required String source,
    required int timestampMs,
    int? level,
    String? loggerName,
    required String message,
    String? error,
    String? stackTrace,
    String? isolateId,
  }) {
    final entry = LogEntry(
      id: _nextId++,
      source: source,
      timestampMs: timestampMs,
      level: level,
      loggerName: loggerName,
      message: message,
      error: error,
      stackTrace: stackTrace,
      isolateId: isolateId,
    );
    _entries.addLast(entry);
    while (_entries.length > capacity) {
      _entries.removeFirst();
    }
    return entry;
  }

  /// Returns entries matching the filters, newest-first.
  List<LogEntry> tail({
    int? sinceId,
    int? levelMin,
    String? loggerContains,
    List<String>? messageContains,
    String? sourceContains,
    String? isolateId,
    int limit = 100,
  }) {
    final lc = loggerContains?.toLowerCase();
    // OR-match: an entry passes if its message contains ANY of the terms.
    final mcTerms = messageContains
            ?.where((t) => t.trim().isNotEmpty)
            .map((t) => t.toLowerCase())
            .toList() ??
        const <String>[];
    final sc = sourceContains?.toLowerCase();
    final iso = isolateId;
    final result = <LogEntry>[];
    // Reverse iterate so newest-first; stop once we hit `limit`.
    final descending = _entries.toList(growable: false).reversed;
    for (final e in descending) {
      if (sinceId != null && e.id <= sinceId) break;
      if (levelMin != null && (e.level ?? 0) < levelMin) continue;
      if (lc != null && !(e.loggerName?.toLowerCase().contains(lc) ?? false)) {
        continue;
      }
      if (mcTerms.isNotEmpty) {
        final msg = e.message.toLowerCase();
        if (!mcTerms.any(msg.contains)) continue;
      }
      if (sc != null && !e.source.toLowerCase().contains(sc)) continue;
      if (iso != null && iso.isNotEmpty && e.isolateId != iso) continue;
      result.add(e);
      if (result.length >= limit) break;
    }
    return result;
  }

  void clear() {
    _entries.clear();
  }
}
