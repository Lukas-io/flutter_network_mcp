import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../storage/captures_db.dart';
import 'result.dart';

final usageStatsTool = Tool(
  name: 'usage_stats',
  description:
      'How agents use this MCP: per tool, call count, outcome (ok/error/'
      'empty), error/empty rates, error breakdown by kind (errorKinds), '
      'degraded/fallback count, p50/p95 latency, avg result size, estimated '
      'token cost (avgEstimatedTokens / totalEstimatedTokens), the '
      'tool->next-tool transition graph tagged with the prior call outcome '
      '(fromOutcome), and selfCorrection (after an error/empty, did the next '
      'call recover). Read-only, process-wide. Opt out with '
      'FLUTTER_NETWORK_MCP_NO_USAGE.',
  inputSchema: Schema.object(
    properties: {
      'sinceMs': Schema.int(
        description: 'Window in ms (e.g. 3600000 = 1h). Omit or 0 for all history.',
      ),
      'topTransitions': Schema.int(
        description: 'How many transitions to return, busiest first. Default 15, cap 100.',
      ),
    },
  ),
);

const int _kRawCap = 50000;

FutureOr<CallToolResult> usageStats(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final sinceRaw = args['sinceMs'] as int?;
  final topRaw = (args['topTransitions'] as int?) ?? 15;
  final topTransitions = topRaw <= 0 ? 15 : (topRaw > 100 ? 100 : topRaw);

  final nowMs = DateTime.now().millisecondsSinceEpoch;
  final cutoff = (sinceRaw == null || sinceRaw <= 0) ? null : nowMs - sinceRaw;

  final List<Map<String, Object?>> rows;
  try {
    rows = CapturesDao().allToolEvents(sinceMs: cutoff, limit: _kRawCap);
  } catch (e) {
    return errorResult('usage_stats query failed: $e', extra: const {
      'nextSteps': [
        'flutter_network_mcp usage — inspect the raw capture from the CLI',
      ],
    });
  }

  final stats = summarizeUsage(rows, topTransitions: topTransitions);
  final tools = stats['tools'] as List;
  final windowDesc = cutoff == null ? 'all history' : _formatWindow(sinceRaw!);

  final summary = rows.isEmpty
      ? 'No tool usage captured over $windowDesc. (Capture is on by default; '
          'opt out with FLUTTER_NETWORK_MCP_NO_USAGE=true.)'
      : '${stats['totalEvents']} call(s) across ${stats['totalTurns']} turn(s) '
          'over $windowDesc, ${tools.length} distinct tool(s).';

  final nextSteps = <String>[];
  if (tools.isNotEmpty) {
    final worst = _highestErrorRate(tools.cast<Map<String, Object?>>());
    if (worst != null && (worst['errorRate'] as num) > 0) {
      nextSteps.add(
        '${worst['tool']} has the highest error rate '
        '(${((worst['errorRate'] as num) * 100).round()}% of '
        '${worst['count']} call(s)) — worth a look',
      );
    }
    nextSteps.add('usage_stats sinceMs:3600000 — narrow to the last hour');
    nextSteps.add('flutter_network_mcp usage --show — raw events from the CLI');
  }

  return jsonResult({
    'summary': summary,
    'window': windowDesc,
    ...stats,
    'nextSteps': nextSteps,
  });
}

/// Aggregates raw `tool_events` rows (ordered by correlation_id, then id) into
/// per-tool stats + the consecutive tool->next-tool transition graph. Visible
/// for testing. Row contract: `correlation_id`, `tool`, `outcome`,
/// `duration_ms` (int?), `result_bytes` (int?).
Map<String, Object?> summarizeUsage(
  List<Map<String, Object?>> rows, {
  int topTransitions = 15,
}) {
  final perTool = <String, _ToolAgg>{};
  final transitions = <String, int>{};
  final selfCorr = <String, List<int>>{};
  final turns = <String>{};
  String? prevCorr;
  String? prevTool;
  String prevOutcome = 'ok';
  String? prevErrorKind;

  for (final r in rows) {
    final corr = (r['correlation_id'] as String?) ?? '';
    final tool = (r['tool'] as String?) ?? '?';
    final outcome = (r['outcome'] as String?) ?? 'ok';
    final errorKind = r['error_kind'] as String?;
    turns.add(corr);
    perTool.putIfAbsent(tool, () => _ToolAgg(tool)).add(
          outcome,
          r['duration_ms'] as int?,
          r['result_bytes'] as int?,
          r['estimated_tokens'] as int?,
          errorKind,
          (r['degraded'] as int? ?? 0) != 0,
        );
    if (prevCorr == corr && prevTool != null) {
      transitions['$prevTool|$prevOutcome|$tool'] =
          (transitions['$prevTool|$prevOutcome|$tool'] ?? 0) + 1;
      final signal = prevOutcome == 'error'
          ? (prevErrorKind ?? 'error')
          : (prevOutcome == 'empty' ? 'empty' : null);
      if (signal != null) {
        final agg = selfCorr.putIfAbsent('$prevTool|$signal', () => [0, 0]);
        agg[0]++;
        if (outcome == 'ok') agg[1]++;
      }
    }
    prevCorr = corr;
    prevTool = tool;
    prevOutcome = outcome;
    prevErrorKind = errorKind;
  }

  final toolsOut = perTool.values.map((a) => a.toJson()).toList()
    ..sort((a, b) => (b['count'] as int).compareTo(a['count'] as int));

  final transOut = transitions.entries.map((e) {
    final parts = e.key.split('|');
    return {
      'from': parts[0],
      'fromOutcome': parts[1],
      'to': parts[2],
      'count': e.value,
    };
  }).toList()
    ..sort((a, b) => (b['count'] as int).compareTo(a['count'] as int));

  final selfCorrOut = selfCorr.entries.map((e) {
    final parts = e.key.split('|');
    final occ = e.value[0];
    final rec = e.value[1];
    return {
      'tool': parts[0],
      'signal': parts[1],
      'occurrences': occ,
      'recovered': rec,
      'recoveryRate':
          occ == 0 ? 0.0 : double.parse((rec / occ).toStringAsFixed(4)),
    };
  }).toList()
    ..sort((a, b) => (b['occurrences'] as int).compareTo(a['occurrences'] as int));

  final grandTotalTokens = perTool.values.fold<int>(0, (s, a) => s + a.tokensSum);
  return {
    'totalEvents': rows.length,
    'totalTurns': turns.length,
    if (grandTotalTokens > 0) 'totalEstimatedTokens': grandTotalTokens,
    'tools': toolsOut,
    'transitions': transOut.take(topTransitions).toList(),
    if (selfCorrOut.isNotEmpty) 'selfCorrection': selfCorrOut,
  };
}

Map<String, Object?>? _highestErrorRate(List<Map<String, Object?>> tools) {
  Map<String, Object?>? worst;
  for (final t in tools) {
    if (worst == null ||
        (t['errorRate'] as num) > (worst['errorRate'] as num)) {
      worst = t;
    }
  }
  return worst;
}

String _formatWindow(int ms) {
  if (ms < 60000) return '${ms}ms';
  if (ms < 3600000) return '${(ms / 60000).round()}m';
  if (ms < 86400000) return '${(ms / 3600000).round()}h';
  return '${(ms / 86400000).round()}d';
}

class _ToolAgg {
  _ToolAgg(this.tool);

  final String tool;
  int count = 0;
  int ok = 0;
  int error = 0;
  int empty = 0;
  final List<int> durations = [];
  int bytesSum = 0;
  int bytesCount = 0;
  int tokensSum = 0;
  int tokensCount = 0;
  int degraded = 0;
  final Map<String, int> errorKinds = {};

  void add(
    String outcome,
    int? durMs,
    int? bytes,
    int? tokens,
    String? errorKind,
    bool isDegraded,
  ) {
    count++;
    switch (outcome) {
      case 'error':
        error++;
      case 'empty':
        empty++;
      default:
        ok++;
    }
    if (durMs != null && durMs >= 0) durations.add(durMs);
    if (bytes != null && bytes >= 0) {
      bytesSum += bytes;
      bytesCount++;
    }
    if (tokens != null && tokens > 0) {
      tokensSum += tokens;
      tokensCount++;
    }
    if (isDegraded) degraded++;
    if (errorKind != null && errorKind.isNotEmpty) {
      errorKinds[errorKind] = (errorKinds[errorKind] ?? 0) + 1;
    }
  }

  Map<String, Object?> toJson() {
    final sorted = [...durations]..sort();
    return {
      'tool': tool,
      'count': count,
      'ok': ok,
      'error': error,
      'empty': empty,
      'errorRate':
          count == 0 ? 0.0 : double.parse((error / count).toStringAsFixed(4)),
      'emptyRate':
          count == 0 ? 0.0 : double.parse((empty / count).toStringAsFixed(4)),
      'p50Ms': _percentile(sorted, 0.50),
      'p95Ms': _percentile(sorted, 0.95),
      if (bytesCount > 0) 'avgResultBytes': (bytesSum / bytesCount).round(),
      if (tokensCount > 0) 'avgEstimatedTokens': (tokensSum / tokensCount).round(),
      if (tokensCount > 0) 'totalEstimatedTokens': tokensSum,
      if (degraded > 0) 'degraded': degraded,
      if (errorKinds.isNotEmpty) 'errorKinds': Map.fromEntries(
          errorKinds.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value))),
    };
  }
}

int? _percentile(List<int> sorted, double p) {
  if (sorted.isEmpty) return null;
  if (sorted.length == 1) return sorted.first;
  final rank = (sorted.length * p).floor();
  return sorted[rank >= sorted.length ? sorted.length - 1 : rank];
}
