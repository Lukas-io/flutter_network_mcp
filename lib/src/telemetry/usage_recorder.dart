import 'dart:io' as io;
import 'dart:math';

import 'package:dart_mcp/server.dart';

import '../storage/captures_db.dart';
import '../storage/database.dart';

/// Records tool-usage events (issue #79, Phase 1). Privacy-safe by
/// construction: only the tool NAME, the arg KEYS the agent passed (never
/// their values), an outcome category, a duration, and a result size are
/// stored. No URLs, hosts, bodies, or log text ever reach it.
///
/// Local-only: events go to the captures DB `tool_events` table. Nothing is
/// shipped anywhere in Phase 1 (aggregate shipping is Phase 3, gated on the
/// collector).
///
/// Default-on. Opt out with `FLUTTER_NETWORK_MCP_NO_TELEMETRY=true` (the same
/// flag that disables crash telemetry) or the granular
/// `FLUTTER_NETWORK_MCP_NO_USAGE=true`.
///
/// Correlation: a per-call id groups a burst of tool calls into one "turn".
/// It rolls over after `FLUTTER_NETWORK_MCP_USAGE_GAP_MS` (default 60s) of
/// inactivity — MCP carries no conversation id, so this gap heuristic is the
/// proxy. The id is `<process-token>-<turnSeq>`, so it carries no PII.
class UsageRecorder {
  /// Visible-for-testing constructor with explicit config.
  UsageRecorder.config({required this.enabled, int gapMs = 60000})
      : _gapMs = gapMs;

  static UsageRecorder? _instance;
  static UsageRecorder get instance => _instance ??= _fromEnv();

  /// Test seams.
  static void overrideForTest(UsageRecorder r) => _instance = r;
  static void resetForTest() => _instance = null;

  static UsageRecorder _fromEnv() {
    final env = io.Platform.environment;
    final off = _truthy(env['FLUTTER_NETWORK_MCP_NO_TELEMETRY']) ||
        _truthy(env['FLUTTER_NETWORK_MCP_NO_USAGE']);
    final gapRaw = int.tryParse(env['FLUTTER_NETWORK_MCP_USAGE_GAP_MS'] ?? '');
    final gap = (gapRaw == null || gapRaw < 1000) ? 60000 : gapRaw;
    return UsageRecorder.config(enabled: !off, gapMs: gap);
  }

  final bool enabled;
  final int _gapMs;

  final String _procToken = _randomToken();
  int _turnSeq = 0;
  int _lastEventMs = 0;
  String _correlationId = '';

  /// Correlation id for an event at [nowMs]. Rolls over after the idle gap.
  /// Stateful + exposed so the rollover logic is unit-testable.
  String correlationIdFor(int nowMs) {
    if (_correlationId.isEmpty || nowMs - _lastEventMs > _gapMs) {
      _turnSeq++;
      _correlationId = '$_procToken-$_turnSeq';
    }
    _lastEventMs = nowMs;
    return _correlationId;
  }

  /// Records one tool call. NEVER throws: a recording failure must not break
  /// the tool call it is measuring. [result] is null when the handler threw.
  void record({
    required String tool,
    required CallToolRequest request,
    required int durationMs,
    required CallToolResult? result,
  }) {
    if (!enabled) return;
    try {
      if (!CapturesDatabase.isOpen) return;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final sc = result?.structuredContent;
      CapturesDao().insertToolEvent(
        tsMs: nowMs,
        correlationId: correlationIdFor(nowMs),
        tool: tool,
        outcome: outcomeFrom(
          threw: result == null,
          isError: result?.isError == true,
          structured: sc,
        ),
        argKeys: argKeysFrom(request.arguments),
        durationMs: durationMs,
        resultBytes: resultBytesOf(result),
        estimatedTokens: _estimateTokens(result),
        errorKind: sc?['errorKind'] as String?,
        degraded: sc?['degraded'] == true,
      );
    } catch (e) {
      io.stderr.writeln('UsageRecorder: record failed (ignored): $e');
    }
  }

  /// Sorted parameter NAMES the agent passed. Keys only, never values.
  static List<String> argKeysFrom(Map<String, Object?>? args) {
    if (args == null || args.isEmpty) return const [];
    return args.keys.toList()..sort();
  }

  /// `ok | error | empty`. `error` = the handler threw or returned isError.
  /// `empty` is a best-effort heuristic (a top-level `count: 0` in the
  /// structured result) refined in Phase 2.
  static String outcomeFrom({
    required bool threw,
    required bool isError,
    Map<String, Object?>? structured,
  }) {
    if (threw || isError) return 'error';
    if (structured != null && structured['count'] == 0) return 'empty';
    return 'ok';
  }

  static int resultBytesOf(CallToolResult? result) {
    if (result == null) return 0;
    var n = 0;
    for (final c in result.content) {
      if (c is TextContent) n += c.text.length;
    }
    return n;
  }

  /// Rough token estimate for the result text (4 chars per token, UTF-8 proxy).
  /// Null when the result is empty or null so the DB column stays NULL rather
  /// than storing a meaningless 0.
  static int? _estimateTokens(CallToolResult? result) {
    final bytes = resultBytesOf(result);
    return bytes > 0 ? (bytes / 4).round() : null;
  }

  static String _randomToken() {
    final r = Random();
    return List.generate(
      4,
      (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  static bool _truthy(String? v) {
    final s = v?.trim().toLowerCase();
    return s == 'true' || s == '1' || s == 'yes' || s == 'on';
  }
}
