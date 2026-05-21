import 'dart:async';
import 'dart:convert';

import 'package:vm_service/vm_service.dart';

import '../alerts/alert_detector.dart';
import '../config/capabilities.dart';
import '../state/log_buffer.dart';
import '../storage/captures_db.dart';

/// Subscribes to the VM service Logging/Stdout/Stderr streams and forwards
/// records into the in-memory [LogBuffer] AND (when [sessionIdProvider]
/// returns non-null) into the captures DB.
class LogStreamSubscriber {
  VmService? _service;
  final List<StreamSubscription<Event>> _subs = [];
  int? Function()? _sessionIdProvider;
  CapturesDao? _dao;
  AlertDetector? _detector;

  bool get isActive => _subs.isNotEmpty;

  Future<void> start(
    VmService service,
    LogBuffer buffer, {
    int? Function()? sessionIdProvider,
  }) async {
    if (isActive) await stop();
    _service = service;
    _sessionIdProvider = sessionIdProvider;
    _dao = sessionIdProvider == null ? null : CapturesDao();
    _detector = sessionIdProvider == null ? null : AlertDetector(_dao!);

    await _safeListen(service, EventStreams.kLogging);
    await _safeListen(service, EventStreams.kStdout);
    await _safeListen(service, EventStreams.kStderr);

    _subs.add(service.onLoggingEvent.listen((event) {
      final record = event.logRecord;
      if (record == null) return;
      const source = 'logging';
      final ts = record.time ?? event.timestamp ?? 0;
      final level = record.level;
      final logger = record.loggerName?.valueAsString;
      final message = record.message?.valueAsString ?? '';
      final err = record.error?.valueAsString;
      final stack = record.stackTrace?.valueAsString;
      buffer.push(
        source: source,
        timestampMs: ts,
        level: level,
        loggerName: logger,
        message: message,
        error: err,
        stackTrace: stack,
      );
      _persist(source: source, timestampMs: ts, level: level, logger: logger, message: message, error: err, stack: stack);
    }));

    _subs.add(service.onStdoutEvent.listen((event) {
      _pushWriteEvent(buffer, event, 'stdout');
    }));
    _subs.add(service.onStderrEvent.listen((event) {
      _pushWriteEvent(buffer, event, 'stderr');
    }));
  }

  Future<void> stop() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    final svc = _service;
    _service = null;
    _sessionIdProvider = null;
    _dao = null;
    _detector = null;
    if (svc == null) return;
    await _safeUnlisten(svc, EventStreams.kLogging);
    await _safeUnlisten(svc, EventStreams.kStdout);
    await _safeUnlisten(svc, EventStreams.kStderr);
  }

  void _pushWriteEvent(LogBuffer buffer, Event event, String source) {
    final raw = event.bytes;
    if (raw == null || raw.isEmpty) return;
    String text;
    try {
      text = utf8.decode(base64.decode(raw), allowMalformed: true);
    } catch (_) {
      text = raw;
    }
    if (text.endsWith('\n')) text = text.substring(0, text.length - 1);
    if (text.isEmpty) return;
    final ts = event.timestamp ?? 0;
    buffer.push(source: source, timestampMs: ts, message: text);
    _persist(source: source, timestampMs: ts, message: text);
  }

  void _persist({
    required String source,
    required int timestampMs,
    int? level,
    String? logger,
    required String message,
    String? error,
    String? stack,
  }) {
    final sid = _sessionIdProvider?.call();
    if (sid == null) return;
    try {
      final rowId = _dao?.insertLog(
        sessionId: sid,
        timestampMs: timestampMs,
        source: source,
        level: level,
        logger: logger,
        message: message,
        error: error,
        stackTrace: stack,
      );
      if (rowId != null &&
          CapabilityConfig.instance.isEnabled(Category.alerts)) {
        _detector?.forLog(
          sessionId: sid,
          logRowId: rowId,
          source: source,
          level: level,
          logger: logger,
          message: message,
          timestampMs: timestampMs,
        );
      }
    } catch (_) {/* DB may be closed during shutdown */}
  }

  Future<void> _safeListen(VmService service, String stream) async {
    try {
      await service.streamListen(stream);
    } catch (_) {/* already listening or unsupported */}
  }

  Future<void> _safeUnlisten(VmService service, String stream) async {
    try {
      await service.streamCancel(stream);
    } catch (_) {/* harmless */}
  }
}
