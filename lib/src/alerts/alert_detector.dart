import 'package:vm_service/vm_service.dart';

import '../storage/captures_db.dart';
import 'alert_rules.dart';

/// Evaluates capture events against [AlertRules] and writes any alerts that
/// fire into the DB. Idempotent — relies on the UNIQUE(session_id, kind,
/// source_id) constraint to dedupe repeat evaluations of the same source.
class AlertDetector {
  AlertDetector(this._dao);

  final CapturesDao _dao;
  final AlertRules _rules = AlertRules.instance;

  /// Evaluates a single HTTP request. Called by the capture writer on every
  /// upsert tick.
  void forHttpRequest(int sessionId, HttpProfileRequest r) {
    final id = r.id;
    final status = r.response?.statusCode;
    final hasError =
        (r.request?.hasError ?? false) || (r.response?.hasError ?? false);

    if (hasError && _rules.httpErrorEnabled) {
      final msg = r.response?.error ?? r.request?.error ?? 'dart:io error';
      _dao.insertAlert(
        sessionId: sessionId,
        severity: 'error',
        kind: 'http_error',
        title: '${r.method} ${r.uri} — request failed',
        detail: msg,
        sourceKind: 'http',
        sourceId: id,
      );
    }

    if (status != null) {
      if (status >= 500 && status <= 599 && _rules.http5xxEnabled) {
        _dao.insertAlert(
          sessionId: sessionId,
          severity: 'error',
          kind: 'http_5xx',
          title: '$status on ${r.method} ${_compact(r.uri)}',
          detail: r.response?.reasonPhrase,
          sourceKind: 'http',
          sourceId: id,
        );
      } else if (status >= 400 && status <= 499 && _rules.http4xxEnabled) {
        _dao.insertAlert(
          sessionId: sessionId,
          severity: 'warning',
          kind: 'http_4xx',
          title: '$status on ${r.method} ${_compact(r.uri)}',
          detail: r.response?.reasonPhrase,
          sourceKind: 'http',
          sourceId: id,
        );
      }
    }

    if (_rules.httpSlowEnabled && r.endTime != null) {
      final ms = r.endTime!.difference(r.startTime).inMilliseconds;
      if (ms > _rules.slowThresholdMs) {
        _dao.insertAlert(
          sessionId: sessionId,
          severity: 'warning',
          kind: 'http_slow',
          title: '${ms}ms on ${r.method} ${_compact(r.uri)}',
          detail: 'Slow request (threshold ${_rules.slowThresholdMs}ms).',
          sourceKind: 'http',
          sourceId: id,
        );
      }
    }
  }

  /// Evaluates a single log record. Called from [LogStreamSubscriber] right
  /// after the record is persisted. [logRowId] is the autogen log_records.id.
  void forLog({
    required int sessionId,
    required int logRowId,
    required String source,
    int? level,
    String? logger,
    required String message,
    int? timestampMs,
  }) {
    if (message.isEmpty) return;

    // Flutter-specific takes priority — it's the most actionable.
    if (_rules.flutterErrorEnabled &&
        AlertRules.flutterErrorPatterns.any((p) => p.hasMatch(message))) {
      _dao.insertAlert(
        sessionId: sessionId,
        severity: 'critical',
        kind: 'flutter_error',
        title: _firstLine(message),
        detail: message.length > 4096 ? message.substring(0, 4096) : message,
        sourceKind: 'log',
        sourceId: 'log:$logRowId',
        tsMs: timestampMs,
      );
      return; // Don't also fire log_keyword for the same record.
    }

    if (_rules.logKeywordEnabled &&
        AlertRules.logKeywordRegex.hasMatch(message)) {
      final severe = (level ?? 0) >= 1200;
      _dao.insertAlert(
        sessionId: sessionId,
        severity: severe ? 'error' : 'warning',
        kind: 'log_keyword',
        title: _firstLine(message),
        detail: message.length > 2048 ? message.substring(0, 2048) : message,
        sourceKind: 'log',
        sourceId: 'log:$logRowId',
        tsMs: timestampMs,
      );
    }

    // Custom user-defined patterns. Run last so they don't pre-empt the
    // built-in flutter_error path, but they CAN fire alongside log_keyword.
    for (final pattern in _rules.customPatterns) {
      if (pattern.regex.hasMatch(message)) {
        _dao.insertAlert(
          sessionId: sessionId,
          severity: pattern.severity,
          kind: pattern.kind,
          title: pattern.label ?? _firstLine(message),
          detail: message.length > 2048 ? message.substring(0, 2048) : message,
          sourceKind: 'log',
          sourceId: 'log:$logRowId:${pattern.id}',
          tsMs: timestampMs,
        );
      }
    }
  }

  static String _compact(Uri uri) {
    final s = uri.toString();
    return s.length > 80 ? '${s.substring(0, 77)}...' : s;
  }

  static String _firstLine(String msg) {
    final i = msg.indexOf('\n');
    final line = i < 0 ? msg : msg.substring(0, i);
    return line.length > 160 ? '${line.substring(0, 157)}...' : line;
  }
}
