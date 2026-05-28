import 'dart:convert';

import 'package:dart_mcp/server.dart';

import '../config/capabilities.dart';
import '../state/session.dart';
import '../storage/captures_db.dart';
import '../storage/database.dart';

/// Builds a [CallToolResult] that carries both a JSON `structuredContent`
/// payload (for the agent to parse) and a pretty-printed text rendering of
/// the same data (so transcripts and inspectors stay readable).
///
/// On non-error results, automatically annotates a top-level
/// `pendingAlerts: N` field when alerts capability is on, the DB is open,
/// and there are undrained alerts in scope. This turns the alerts pipeline
/// from poll-only into push-like: any tool the agent calls surfaces fresh
/// alert counts without needing a network_status round trip. Tools that
/// already carry alert data (alerts_drain / alerts_peek / network_status)
/// are skipped so the field doesn't shadow their richer reporting.
///
/// **Multi-attach (Phase 4):** when [scopeSessionId] is passed, the
/// annotation is scoped to that one session's pending alert count rather
/// than process-wide. Tools that resolved a [Scope] should pass their
/// `scope.sessionId` so the agent sees alerts for the session they just
/// read from — preventing cross-app data bleed in the push-like signal.
/// When null (no scope), falls back to `Session.instance.effectiveSessionId`
/// (same behaviour as before Phase 4) — in multi-attach with 2+ sessions
/// that returns null, so the annotation counts across all sessions (the
/// only legitimate cross-session aggregate: alerts the agent might miss
/// before picking a scope).
CallToolResult jsonResult(
  Map<String, Object?> data, {
  bool isError = false,
  int? scopeSessionId,
}) {
  final payload =
      isError ? data : _maybeAnnotatePendingAlerts(data, scopeSessionId);
  final pretty = const JsonEncoder.withIndent('  ').convert(payload);
  return CallToolResult(
    content: [TextContent(text: pretty)],
    structuredContent: payload,
    isError: isError,
  );
}

CallToolResult errorResult(String message, {Map<String, Object?>? extra}) {
  return jsonResult({
    'error': message,
    if (extra != null) ...extra,
  }, isError: true);
}

/// Inserts `pendingAlerts: N` into [data] when alerts are pending in scope.
/// Best-effort: any DB hiccup falls through silently so this never blocks a
/// tool response.
Map<String, Object?> _maybeAnnotatePendingAlerts(
  Map<String, Object?> data,
  int? scopeSessionId,
) {
  // Don't shadow tools that already report alert counts in richer shapes.
  if (data.containsKey('alerts') || data.containsKey('pendingAlerts')) {
    return data;
  }
  if (!CapabilityConfig.instance.isEnabled(Category.alerts)) return data;
  if (!CapturesDatabase.isOpen) return data;
  try {
    final sid = scopeSessionId ?? Session.instance.effectiveSessionId;
    final dao = CapturesDao();
    final pending = dao.pendingAlertCount(sessionId: sid);
    if (pending == 0) return data;
    final critical = dao.pendingAlertCount(
      sessionId: sid,
      severityMin: 'critical',
    );
    return {
      ...data,
      'pendingAlerts': {
        'count': pending,
        if (critical > 0) 'critical': critical,
      },
    };
  } catch (_) {
    return data;
  }
}
